const std = @import("std");
const media = @import("../media.zig");
const vtb = @import("videotoolbox_c.zig");

pub const MTLDeviceRef = vtb.MTLDeviceRef;

const Allocator = std.mem.Allocator;
const Io = std.Io;
pub const log = std.log.scoped(.videoToolBox);

/// For packed y416 format (kCVPixelFormatType_4444AYpCbCr16), we use a single RGBA16Unorm texture.
/// The 64-bit AYUV data maps to Metal's RGBA16 as: R=A, G=Y, B=Cb, A=Cr
pub const MetalTextureSet = struct {
    texture: vtb.CVMetalTextureRef, // Single packed AYUV texture

    pub fn getMetalTexture(self: *const MetalTextureSet) vtb.MTLTextureRef {
        return vtb.CVMetalTextureGetTexture(self.texture);
    }

    pub fn deinit(self: *MetalTextureSet) void {
        vtb.CFRelease(self.texture);
    }
};

pub const VideoToolboxDecoder = struct {
    session: vtb.VTDecompressionSessionRef,
    format_desc: vtb.CMVideoFormatDescriptionRef,
    frame_ctx: *FrameContext,
    source_media: *const media.SourceMedia, // Reference to clip
    texture_cache: vtb.CVMetalTextureCacheRef, // Metal texture cache for zero-copy textures
    metal_device: vtb.MTLDeviceRef, // Metal device

    pub fn init(
        source_media: *const media.SourceMedia,
        metal_device: vtb.MTLDeviceRef,
    ) !VideoToolboxDecoder {
        // Register professional video workflow decoders (ProRes, etc.)
        // This ensures we get native ProRes output formats without conversion
        const register_status = vtb.VTRegisterProfessionalVideoWorkflowVideoDecoders();
        if (register_status == vtb.noErr) {
            std.debug.print("✓ Registered professional video decoders\n", .{});
        } else {
            std.debug.print("⚠ Failed to register professional decoders: {}\n", .{register_status});
        }

        const format_desc = try createFormatDescription(source_media);

        // Check Fmt Description
        try verifyFmtDes(format_desc);

        const frame_ctx_ptr = try source_media.mctx.allocator.create(FrameContext);
        frame_ctx_ptr.* = FrameContext{ .pixel_buffer = null };
        const session = try createDecompressionSession(format_desc, frame_ctx_ptr);

        // Create Metal texture cache for zero-copy rendering
        var texture_cache: vtb.CVMetalTextureCacheRef = undefined;
        const cache_status = vtb.CVMetalTextureCacheCreate(
            vtb.kCFAllocatorDefault,
            null, // cache attributes
            metal_device,
            null, // texture attributes
            &texture_cache,
        );
        if (cache_status != vtb.noErr) {
            return error.TextureCacheCreationFailed;
        }

        return .{
            .session = session,
            .format_desc = format_desc,
            .frame_ctx = frame_ctx_ptr,
            .source_media = source_media,
            .texture_cache = texture_cache,
            .metal_device = metal_device,
        };
    }

    pub fn decodeFrame(self: *VideoToolboxDecoder, frame_index: usize) !DecodedFrame {
        self.frame_ctx.pixel_buffer = null;

        const frame_size = try self.source_media.getFrameSize(frame_index);
        // std.debug.print("\nFirst frame size: {d} bytes\n", .{frame_size});

        const buffer = try self.source_media.mctx.allocator.alloc(u8, frame_size);
        defer self.source_media.mctx.allocator.free(buffer);

        _ = try self.source_media.readFrame(frame_index, buffer);
        // std.debug.print("Read {d} bytes from frame 0\n", .{bytes_read});

        const block_buffer = try createBlockBuffer(buffer);
        // std.debug.print("block_buffer: {*}\n", .{block_buffer});

        const timing_info = createSampleTimingInfo(frame_index, self.source_media);
        const sample_buffer = try createSampleBuffer(block_buffer, timing_info, self.format_desc);
        defer vtb.CFRelease(sample_buffer);

        // Phase 4.5: Decode the frame
        try decompress(self.session, sample_buffer);

        // return self.frame_ctx.pixel_buffer orelse error.DecodeFrameFailed;

        // Now frame_ctx.pixel_buffer contains the decoded frame
        if (self.frame_ctx.pixel_buffer) |pb| {
            try cpuInspectPixelBufferData(pb);

            return DecodedFrame{ .pixel_buffer = pb };
        } else {
            return error.DecodeFrameFailed;
        }
    }

    /// Creates Metal texture from CVPixelBuffer for packed y416 format.
    /// y416 (kCVPixelFormatType_4444AYpCbCr16) is PACKED: 8 bytes per pixel [A16][Y16][Cb16][Cr16]
    /// We map this to a single RGBA16Unorm texture where R=A, G=Y, B=Cb, A=Cr
    pub fn createMetalTextures(
        self: *const VideoToolboxDecoder,
        pixel_buffer: vtb.CVPixelBufferRef,
    ) !MetalTextureSet {
        // Get both overall and plane-specific dimensions (FFmpeg uses plane-specific)
        const width = vtb.CVPixelBufferGetWidth(pixel_buffer);
        const height = vtb.CVPixelBufferGetHeight(pixel_buffer);
        const plane_width = vtb.CVPixelBufferGetWidthOfPlane(pixel_buffer, 0);
        const plane_height = vtb.CVPixelBufferGetHeightOfPlane(pixel_buffer, 0);

        // Debug: Print info once
        const State = struct {
            var printed: bool = false;
        };
        if (!State.printed) {
            State.printed = true;

            inspectColorSpaceMetadata(pixel_buffer);

            const planes = vtb.CVPixelBufferGetPlaneCount(pixel_buffer);
            const bytes_per_row = vtb.CVPixelBufferGetBytesPerRow(pixel_buffer);
            const plane_bytes_per_row = vtb.CVPixelBufferGetBytesPerRowOfPlane(pixel_buffer, 0);
            const pixel_format = vtb.CVPixelBufferGetPixelFormatType(pixel_buffer);
            const format_bytes: [4]u8 = @bitCast(pixel_format);

            std.debug.print("\n🔍 PACKED Y416 TEXTURE CREATION:\n", .{});
            std.debug.print("   Pixel Format: 0x{X:0>8} ('{s}')\n", .{ pixel_format, &format_bytes });
            std.debug.print("   Overall Dimensions: {}x{}\n", .{ width, height });
            std.debug.print("   Plane 0 Dimensions: {}x{}\n", .{ plane_width, plane_height });
            std.debug.print("   Bytes per row (overall): {}\n", .{bytes_per_row});
            std.debug.print("   Bytes per row (plane 0): {}\n", .{plane_bytes_per_row});
            std.debug.print("   Expected for y416: {} * 8 = {}\n", .{ width, width * 8 });
            std.debug.print("   Plane count: {} (0 = non-planar/packed)\n", .{planes});
            std.debug.print("   Creating RGBA16Unorm texture for packed AYUV data\n", .{});
        }

        // Use plane-specific dimensions like FFmpeg does
        const tex_width = if (plane_width > 0) plane_width else width;
        const tex_height = if (plane_height > 0) plane_height else height;

        // Go back to RGBA16Unorm at normal width.
        // We discovered that R channel reads correctly (solid grey),
        // but G/B/A channels have stripe artifacts.
        // The IOSurface doesn't properly map to RGBA16Unorm channels.
        //
        // The working approach: use RGBA16Unorm and only trust even-X pixels
        // (the stripe pattern suggests odd pixels have garbage data)
        var packed_texture: vtb.CVMetalTextureRef = undefined;
        const status = vtb.CVMetalTextureCacheCreateTextureFromImage(
            vtb.kCFAllocatorDefault,
            self.texture_cache,
            pixel_buffer,
            null, // no texture attributes
            vtb.MTLPixelFormatRGBA16Unorm, // Back to RGBA16
            tex_width,
            tex_height,
            0, // plane index 0 (only plane for packed format)
            &packed_texture,
        );

        if (status != vtb.noErr) {
            std.debug.print("❌ Failed to create packed RGBA16Unorm texture: {}\n", .{status});
            return error.TextureCreationFailed;
        }

        const result = MetalTextureSet{
            .texture = packed_texture,
        };
        return result;
    }

    pub fn inspectColorSpaceMetadata(pixel_buffer: vtb.CVPixelBufferRef) void {
        std.debug.print("\n🎨 COLOR SPACE METADATA:\n", .{});

        // Helper to query and print an attachment
        const queryAttachment = struct {
            fn query(pb: vtb.CVPixelBufferRef, key_cstr: [*:0]const u8, name: []const u8) void {
                const key = vtb.CFStringCreateWithCString(
                    vtb.kCFAllocatorDefault,
                    key_cstr,
                    vtb.kCFStringEncodingUTF8,
                );
                defer vtb.CFRelease(key);

                const value = vtb.CVBufferGetAttachment(pb, key, null);
                if (value) |v| {
                    // Try to get as CFString
                    const str_ptr = vtb.CFStringGetCStringPtr(@ptrCast(v), vtb.kCFStringEncodingUTF8);
                    if (str_ptr) |s| {
                        std.debug.print("   {s}: {s}\n", .{ name, s });
                    } else {
                        std.debug.print("   {s}: <present but not string>\n", .{name});
                    }
                } else {
                    std.debug.print("   {s}: <not found>\n", .{name});
                }
            }
        }.query;

        queryAttachment(pixel_buffer, vtb.kCVImageBufferYCbCrMatrixKey, "YCbCr Matrix");
        queryAttachment(pixel_buffer, vtb.kCVImageBufferColorPrimariesKey, "Color Primaries");
        queryAttachment(pixel_buffer, vtb.kCVImageBufferTransferFunctionKey, "Transfer Function");
        queryAttachment(pixel_buffer, vtb.kCVImageBufferChromaLocationTopFieldKey, "Chroma Location (Top)");
        queryAttachment(pixel_buffer, vtb.kCVImageBufferChromaLocationBottomFieldKey, "Chroma Location (Bottom)");

        // Query bit depth
        const depth_key = vtb.CFStringCreateWithCString(
            vtb.kCFAllocatorDefault,
            vtb.kCMFormatDescriptionExtension_Depth,
            vtb.kCFStringEncodingUTF8,
        );
        defer vtb.CFRelease(depth_key);

        const depth_value = vtb.CVBufferGetAttachment(pixel_buffer, depth_key, null);
        if (depth_value) |v| {
            var depth: i32 = 0;
            if (vtb.CFNumberGetValue(@ptrCast(v), vtb.kCFNumberSInt32Type, &depth) != 0) {
                std.debug.print("   Bit Depth: {}\n", .{depth});
            }
        } else {
            std.debug.print("   Bit Depth: <not found>\n", .{});
        }

        // Query full range flag
        const range_key = vtb.CFStringCreateWithCString(
            vtb.kCFAllocatorDefault,
            vtb.kCMFormatDescriptionExtension_FullRangeVideo,
            vtb.kCFStringEncodingUTF8,
        );
        defer vtb.CFRelease(range_key);

        const range_value = vtb.CVBufferGetAttachment(pixel_buffer, range_key, null);
        if (range_value) |v| {
            const is_full_range = vtb.CFBooleanGetValue(v) != 0;
            std.debug.print("   Full Range: {}\n", .{is_full_range});
        } else {
            std.debug.print("   Full Range: <not found>\n", .{});
        }
    }

    pub fn cpuInspectPixelBufferData(pixel_buffer: vtb.CVPixelBufferRef) !void {

        // Lock for read-only access
        const lock_status = vtb.CVPixelBufferLockBaseAddress(pixel_buffer, 0x00000001); // kCVPixelBufferLock_ReadOnly
        if (lock_status != vtb.noErr) {
            std.debug.print("❌ Failed to lock pixel buffer: {d}\n", .{lock_status});
            return;
        }
        defer _ = vtb.CVPixelBufferUnlockBaseAddress(pixel_buffer, 0);

        // Get pixel buffer dimensions and format
        const width = vtb.CVPixelBufferGetWidth(pixel_buffer);
        const height = vtb.CVPixelBufferGetHeight(pixel_buffer);
        const bytes_per_row = vtb.CVPixelBufferGetBytesPerRow(pixel_buffer);
        const pixel_format = vtb.CVPixelBufferGetPixelFormatType(pixel_buffer);

        // Format as readable string
        const format_bytes: [4]u8 = @bitCast(pixel_format);

        std.debug.print("\n📊 CVPixelBuffer Inspector:\n", .{});
        std.debug.print("   Dimensions: {d}x{d}\n", .{ width, height });
        std.debug.print("   Pixel Format: 0x{X:0>8} ('{s}')\n", .{ pixel_format, &format_bytes });
        std.debug.print("   Bytes per Row: {d}\n", .{bytes_per_row});
        std.debug.print("   Total Size: {d} bytes\n", .{bytes_per_row * height});

        const planes = vtb.CVPixelBufferGetPlaneCount(pixel_buffer);
        std.debug.print("planes: {any}\n", .{planes});

        // For packed formats (plane count = 0), read from base address directly
        if (planes == 0) {
            const base_address = vtb.CVPixelBufferGetBaseAddress(pixel_buffer);
            if (base_address) |addr| {
                const pixel_data: [*]const u8 = @ptrCast(addr);
                std.debug.print("\n=== PACKED FORMAT DATA ===\n", .{});
                std.debug.print("   y416 layout: [A16][Y16][Cb16][Cr16] = 8 bytes per pixel\n", .{});

                // Show first 4 pixels (32 bytes)
                std.debug.print("   First 4 pixels (32 bytes):\n   ", .{});
                for (0..32) |i| {
                    std.debug.print("{X:0>2} ", .{pixel_data[i]});
                    if ((i + 1) % 8 == 0) std.debug.print("| ", .{});
                }

                // Interpret as 16-bit values
                std.debug.print("\n   As 16-bit values (first 2 pixels):\n", .{});
                const u16_data: [*]const u16 = @ptrCast(@alignCast(addr));
                std.debug.print("   Pixel 0: A={d}, Y={d}, Cb={d}, Cr={d}\n", .{
                    u16_data[0], u16_data[1], u16_data[2], u16_data[3],
                });
                std.debug.print("   Pixel 1: A={d}, Y={d}, Cb={d}, Cr={d}\n", .{
                    u16_data[4], u16_data[5], u16_data[6], u16_data[7],
                });

                // Show middle of frame (width/2) to see Red half
                const mid_x_offset: usize = @intCast((width / 2) * 8); // 8 bytes per pixel
                std.debug.print("   Pixel at x={d} (should be red half):\n", .{width / 2});
                std.debug.print("   A={d}, Y={d}, Cb={d}, Cr={d}\n", .{
                    u16_data[mid_x_offset / 2],
                    u16_data[mid_x_offset / 2 + 1],
                    u16_data[mid_x_offset / 2 + 2],
                    u16_data[mid_x_offset / 2 + 3],
                });
            }
        }

        const plane_names = [_][]const u8{ "Y (Luma)", "CbCr (Chroma Interleaved)", "Alpha" };

        for (0..planes) |plane| {
            const plane_address = vtb.CVPixelBufferGetBaseAddressOfPlane(pixel_buffer, plane);
            if (plane_address == null) {
                std.debug.print("❌ Failed to get plane {d} address\n", .{plane});
                continue;
            }

            const plane_width = vtb.CVPixelBufferGetWidthOfPlane(pixel_buffer, plane);
            const plane_height = vtb.CVPixelBufferGetHeightOfPlane(pixel_buffer, plane);
            const plane_bpr = vtb.CVPixelBufferGetBytesPerRowOfPlane(pixel_buffer, plane);

            const plane_name = if (plane < plane_names.len) plane_names[plane] else "Unknown";
            std.debug.print("\n=== PLANE {d}: {s} ===\n", .{ plane, plane_name });
            std.debug.print("   Size: {d}x{d}, Bytes per row: {d}\n", .{ plane_width, plane_height, plane_bpr });

            const pixel_data: [*]const u8 = @ptrCast(plane_address);

            // First row sample
            std.debug.print("   First row (first 32 bytes):\n   ", .{});
            for (0..32) |i| {
                std.debug.print("{X:0>2} ", .{pixel_data[i]});
                if ((i + 1) % 16 == 0) std.debug.print("\n   ", .{});
            }

            // Last 32 bytes
            std.debug.print("First row (last 32 bytes):\n   ", .{});
            const tail = plane_bpr - 32;
            for (tail..plane_bpr) |i| {
                std.debug.print("{X:0>2} ", .{pixel_data[i]});
                if ((i + 1) % 16 == 0) std.debug.print("\n   ", .{});
            }

            // // Middle row sample
            // const middle_row_offset = (plane_height / 2) * plane_bpr;
            // std.debug.print("\n   Middle row (first 32 bytes):\n   ", .{});
            // for (0..32) |i| {
            //     std.debug.print("{X:0>2} ", .{pixel_data[middle_row_offset + i]});
            //     if ((i + 1) % 16 == 0) std.debug.print("\n   ", .{});
            // }

            std.debug.print("\n", .{});
        }

        std.debug.print("\n", .{});
    }

    pub fn deinit(self: *VideoToolboxDecoder) void {
        vtb.CFRelease(self.format_desc);
        vtb.VTDecompressionSessionInvalidate(self.session);
        vtb.CFRelease(self.session);
        vtb.CFRelease(self.texture_cache);
        self.source_media.mctx.allocator.destroy(self.frame_ctx);
    }
};

const VideoToolboxError = error{
    CreateFormatDescriptionFailed,
    CreateDecompressionSessionFailed,
    CreateBlockBufferFailed,
    CreateSampleBufferFailed,
    DecodeFrameFailed,
    DecoderWaitFailed,
    TextureCreationFailed,
};
const FrameContext = struct {
    pixel_buffer: ?vtb.CVPixelBufferRef,
};

pub const DecodedFrame = struct {
    pixel_buffer: vtb.CVPixelBufferRef,

    pub fn deinit(self: *const DecodedFrame) void {
        vtb.CFRelease(self.pixel_buffer);
    }
};

// Callback that receives decoded frames from VideoToolbox
export fn decompressionOutputCallback(
    decompressionOutputRefCon: ?*anyopaque,
    sourceFrameRefCon: ?*anyopaque,
    status: vtb.OSStatus,
    infoFlags: u32,
    imageBuffer: vtb.CVPixelBufferRef,
    presentationTimeStamp: vtb.CMTime,
    presentationDuration: vtb.CMTime,
) callconv(.c) void {
    if (status != vtb.noErr) {
        std.debug.print("❌ Decode callback error: {d}\n", .{status});
        return;
    }

    if (decompressionOutputRefCon) |ctx_ptr| {
        const ctx: *FrameContext = @ptrCast(@alignCast(ctx_ptr));
        ctx.pixel_buffer = imageBuffer;
        _ = vtb.CFRetain(imageBuffer); // Keep it alive beyond callback
    }
    _ = sourceFrameRefCon;
    _ = infoFlags;
    _ = presentationTimeStamp;
    _ = presentationDuration;

    // // Extract pixel buffer information
    // const width = vtb.CVPixelBufferGetWidth(imageBuffer);
    // const height = vtb.CVPixelBufferGetHeight(imageBuffer);
    // const pixel_format = vtb.CVPixelBufferGetPixelFormatType(imageBuffer);
    // const bytes_per_row = vtb.CVPixelBufferGetBytesPerRow(imageBuffer);
    //
    // // Convert pixel format to readable string
    // const format_bytes: [4]u8 = @bitCast(pixel_format);
    //
    // std.debug.print("   Decoded CVPixelBuffer:\n", .{});
    // std.debug.print("   Resolution: {d}x{d}\n", .{ width, height });
    // std.debug.print("   Pixel Format: 0x{X:0>8} ('{s}')\n", .{ pixel_format, &format_bytes });
    // std.debug.print("   Bytes per Row: {d}\n", .{bytes_per_row});
    // std.debug.print("   Total Size: {d} bytes\n", .{bytes_per_row * height});
}

fn createFormatDescription(source_media: *const media.SourceMedia) !vtb.CMVideoFormatDescriptionRef {
    var format_desc: vtb.CMVideoFormatDescriptionRef = null;

    // stsd atom structure:
    // 0-3: version/flags (4 bytes)
    // 4-7: entry count (4 bytes)
    // 8+:  ImageDescription data
    const image_desc_offset = 8;

    if (source_media.stsd_data.len < image_desc_offset) {
        std.debug.print("stsd_data too small: {d} bytes\n", .{source_media.stsd_data.len});
        return error.CreateFormatDescriptionFailed;
    }

    const image_desc_data = source_media.stsd_data[image_desc_offset..];

    // Use the QuickTime-specific function that takes raw ImageDescription data
    const status = vtb.CMVideoFormatDescriptionCreateFromBigEndianImageDescriptionData(
        null,
        image_desc_data.ptr,
        image_desc_data.len,
        vtb.CFStringGetSystemEncoding(),
        null, // NULL = QuickTimeMovie flavor (default)
        &format_desc,
    );

    if (status != vtb.noErr) {
        std.debug.print("CMVideoFormatDescriptionCreateFromBigEndianImageDescriptionData failed: {d}\n", .{status});
        return error.CreateFormatDescriptionFailed;
    }
    return format_desc.?;
}

fn createDecompressionSession(
    format_desc: vtb.CMVideoFormatDescriptionRef,
    frame_ctx: *FrameContext,
) !vtb.VTDecompressionSessionRef {

    // Let VideoToolbox choose the best format - just request Metal compatibility
    // For ProRes 4444, it typically chooses '&sv4' (bi-planar 16-bit 4:4:4 with alpha)
    const keys = [_]?*const anyopaque{
        @ptrCast(vtb.kCVPixelBufferMetalCompatibilityKey),
    };
    const values = [_]?*const anyopaque{
        @ptrCast(vtb.kCFBooleanTrue),
    };

    const pixel_attrs = vtb.CFDictionaryCreate(
        null,
        &keys[0],
        &values[0],
        1,
        null,
        null,
    );
    defer vtb.CFRelease(pixel_attrs);

    // Create callback record
    const callback_record = vtb.VTDecompressionOutputCallbackRecord{
        .decompressionOutputCallback = decompressionOutputCallback,
        .decompressionOutputRefCon = frame_ctx,
    };

    // Create decompression session
    var session: vtb.VTDecompressionSessionRef = null;
    const status = vtb.VTDecompressionSessionCreate(
        null, // allocator
        format_desc,
        null, // Let VideoToolbox choose decoder automatically
        pixel_attrs, // BGRA + Metal compatible output
        &callback_record,
        &session,
    );

    if (status != vtb.noErr) {
        std.debug.print("VTDecompressionSessionCreate failed: {d}\n", .{status});
        return error.CreateDecompressionSessionFailed;
    }

    // DEBUG: Print supported pixel formats
    var props: ?*anyopaque = null;
    const prop_status = vtb.VTSessionCopyProperty(
        session,
        vtb.kVTDecompressionPropertyKey_SupportedPixelFormatsOrderedByQuality,
        null,
        &props,
    );
    if (prop_status == vtb.noErr and props != null) {
        std.debug.print("\n📋 Supported Pixel Formats (ordered by quality):\n", .{});
        const count = vtb.CFArrayGetCount(@ptrCast(props));
        std.debug.print("   Count: {}\n", .{count});
        for (0..@intCast(count)) |i| {
            const num = vtb.CFArrayGetValueAtIndex(@ptrCast(props), @intCast(i));
            var format: u32 = 0;
            _ = vtb.CFNumberGetValue(@ptrCast(@alignCast(@constCast(num))), vtb.kCFNumberSInt32Type, &format);
            const bytes = @as([4]u8, @bitCast(format));
            std.debug.print("   [{}] 0x{X:0>8} ('{c}{c}{c}{c}')\n", .{ i, format, bytes[3], bytes[2], bytes[1], bytes[0] });
        }
        vtb.CFRelease(props.?);
    }

    // std.debug.print("✅ Decompression session created successfully!\n", .{});
    return session.?;
}

fn createBlockBuffer(frame_data: []u8) !vtb.CMBlockBufferRef {
    var block_buffer: vtb.CMBlockBufferRef = null;

    const status = vtb.CMBlockBufferCreateWithMemoryBlock(
        vtb.kCFAllocatorDefault,
        frame_data.ptr,
        frame_data.len,
        vtb.kCFAllocatorNull,
        null,
        0,
        frame_data.len,
        0,
        &block_buffer,
    );

    if (status != vtb.noErr) {
        return error.CreateBlockBufferFailed;
    }

    return block_buffer.?;
}

fn createSampleTimingInfo(
    frame_index: usize,
    source_media: *const media.SourceMedia,
) vtb.CMSampleTimingInfo {
    // PTS = frame_index × frame_duration / timescale
    // For frame 0: PTS = 0
    const pts_value: i64 = @as(i64, @intCast(frame_index)) * @as(i64, @intCast(source_media.frame_rate.den));
    const pts = vtb.CMTimeMake(pts_value, @as(i32, @intCast(source_media.frame_rate.num)));

    // Duration = frame_duration / timescale
    const duration = vtb.CMTimeMake(
        @as(i64, @intCast(source_media.frame_rate.den)),
        @as(i32, @intCast(source_media.frame_rate.num)),
    );

    // DTS (decode timestamp) is usually same as PTS for intraframe codecs like ProRes
    const dts = pts;

    return .{
        .duration = duration,
        .presentationTimeStamp = pts,
        .decodeTimeStamp = dts,
    };
}

fn createSampleBuffer(
    block_buffer: vtb.CMBlockBufferRef,
    timing_info: vtb.CMSampleTimingInfo,
    format_desc: vtb.CMVideoFormatDescriptionRef,
) !vtb.CMSampleBufferRef {
    var sample_buffer: vtb.CMSampleBufferRef = null;

    const status = vtb.CMSampleBufferCreateReady(
        vtb.kCFAllocatorDefault, // allocator
        block_buffer, // dataBuffer (our block buffer)
        format_desc, // formatDescription
        1, // numSamples (1 frame)
        1, // numSampleTimingEntries
        &[_]vtb.CMSampleTimingInfo{timing_info}, // sampleTimingArray
        0, // numSampleSizeEntries
        null, // sampleSizeArray
        &sample_buffer, // sampleBufferOut
    );

    if (status != vtb.noErr) {
        return error.CreateSampleBufferFailed;
    }

    return sample_buffer.?;
}

fn decompress(
    session: vtb.VTDecompressionSessionRef,
    sample_buffer: vtb.CMSampleBufferRef,
) !void {
    const status = vtb.VTDecompressionSessionDecodeFrame(
        session,
        sample_buffer,
        0, // decodeFlags: no special options
        null, // sourceFrameRefCon: context for callback
        null, // infoFlagsOut: output flags
    );

    if (status != vtb.noErr) {
        std.debug.print("VTDecompressionSessionDecodeFrame failed: {d}\n", .{status});
        return error.DecodeFrameFailed;
    }

    // Wait for decoder to finish (blocks until callback completes)
    const wait_status = vtb.VTDecompressionSessionWaitForAsynchronousFrames(session);
    if (wait_status != vtb.noErr) {
        std.debug.print("VTDecompressionSessionWaitForAsynchronousFrames failed: {d}\n", .{wait_status});
        return error.DecoderWaitFailed;
    }
}

pub fn decode(source_media: *const media.SourceMedia) !void {
    std.debug.print("\n=== VideoToolbox Tests ===\n", .{});

    const format_desc = try createFormatDescription(source_media);
    defer vtb.CFRelease(format_desc);

    // Check Fmt Description
    try verifyFmtDes(format_desc);

    // Check if hardware decode is supported for this codec
    const codec_type = vtb.CMFormatDescriptionGetMediaSubType(format_desc);
    const hw_supported = vtb.VTIsHardwareDecodeSupported(codec_type);
    std.debug.print("Hardware decode supported: {}\n", .{hw_supported != 0});

    var frame_ctx = FrameContext{ .pixel_buffer = null };

    const session = try createDecompressionSession(format_desc, &frame_ctx);
    defer {
        vtb.VTDecompressionSessionInvalidate(session);
        vtb.CFRelease(session);
    }

    std.debug.print("VTDecompressionSession created successfully!\n", .{});

    const frame_size = try source_media.getFrameSize(0);
    std.debug.print("\nFirst frame size: {d} bytes\n", .{frame_size});

    const buffer = try source_media.mctx.allocator.alloc(u8, frame_size);

    const bytes_read = try source_media.readFrame(0, buffer);
    std.debug.print("Read {d} bytes from frame 0\n", .{bytes_read});

    const block_buffer = try createBlockBuffer(buffer);
    std.debug.print("block_buffer: {*}\n", .{block_buffer});

    const timing_info = createSampleTimingInfo(0, source_media);
    const sample_buffer = try createSampleBuffer(block_buffer, timing_info, format_desc);

    std.debug.print("sample_buffer: {*}\n", .{sample_buffer});

    // Phase 4.5: Decode the frame
    try decompress(session, sample_buffer);

    // Now frame_ctx.pixel_buffer contains the decoded frame!
    if (frame_ctx.pixel_buffer) |pb| {
        std.debug.print("Got pixel buffer: {*}\n", .{pb});
        // ... do stuff with it ...
        vtb.CFRelease(pb); // Release when done
    }

    defer vtb.CFRelease(sample_buffer);

    defer source_media.mctx.allocator.free(buffer);

    //  Check agian after defers
    if (frame_ctx.pixel_buffer) |pb| {
        // vtb.CFRelease(pb); // Release when done
        std.debug.print("Check agian after CFRealease(pb) + defers....\nGot pixel buffer: {*}\n", .{pb});
    }
}

//
//
/// Debug test checks
fn verifyFmtDes(format_desc: vtb.CMVideoFormatDescriptionRef) !void {
    std.debug.print("Format description created: {*}\n", .{format_desc});

    // Verify the codec type
    const codec_type = vtb.CMFormatDescriptionGetMediaSubType(format_desc);
    const codec_bytes: [4]u8 = @bitCast(codec_type);
    std.debug.print("   Codec FourCC: 0x{X:0>8} ('{s}')\n", .{
        codec_type,
        &codec_bytes,
    });

    // Verify dimensions
    const dims = vtb.CMVideoFormatDescriptionGetDimensions(format_desc);
    std.debug.print("   Dimensions: {d}x{d}\n", .{ dims.width, dims.height });
}
