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
            try cpuInspectPixelBufferData(pb); // CPU PixBuf check

            return DecodedFrame{ .pixel_buffer = pb };
        } else {
            return error.DecodeFrameFailed;
        }
    }

    /// Creates Metal texture from CVPixelBuffer.
    /// Now supports BGRA format (VideoToolbox converts YCbCr to RGB for us)
    pub fn createMetalTextures(
        self: *const VideoToolboxDecoder,
        pixel_buffer: vtb.CVPixelBufferRef,
    ) !MetalTextureSet {
        const width = vtb.CVPixelBufferGetWidth(pixel_buffer);
        const height = vtb.CVPixelBufferGetHeight(pixel_buffer);
        const pixel_format = vtb.CVPixelBufferGetPixelFormatType(pixel_buffer);

        // Debug: Print info once
        const State = struct {
            var printed: bool = false;
        };
        if (!State.printed) {
            State.printed = true;
            const bytes_per_row = vtb.CVPixelBufferGetBytesPerRow(pixel_buffer);
            const format_bytes: [4]u8 = @bitCast(pixel_format);
            const bits_per_pixel = (bytes_per_row * 8) / width;
            std.debug.print("\n🎬 Video texture: {d}x{d}, {s} ({d}-bit/pixel)\n", .{ width, height, &format_bytes, bits_per_pixel });
        }

        // Choose Metal pixel format based on CVPixelBuffer format
        const metal_format: vtb.MTLPixelFormat = switch (pixel_format) {
            vtb.kCVPixelFormatType_32BGRA => vtb.MTLPixelFormatBGRA8Unorm,
            vtb.kCVPixelFormatType_64RGBAHalf => vtb.MTLPixelFormatRGBA16Float, // Half-float
            vtb.kCVPixelFormatType_64ARGB => vtb.MTLPixelFormatRGBA16Unorm,
            vtb.kCVPixelFormatType_4444AYpCbCr16 => vtb.MTLPixelFormatRGBA16Unorm,
            else => {
                const format_bytes: [4]u8 = @bitCast(pixel_format);
                std.debug.print("Unknown pixel format: 0x{X:0>8} ('{s}')\n", .{ pixel_format, &format_bytes });
                return error.UnsupportedPixelFormat;
            },
        };

        var texture: vtb.CVMetalTextureRef = undefined;
        const status = vtb.CVMetalTextureCacheCreateTextureFromImage(
            vtb.kCFAllocatorDefault,
            self.texture_cache,
            pixel_buffer,
            null,
            metal_format,
            width,
            height,
            0,
            &texture,
        );

        if (status != vtb.noErr) {
            std.debug.print("❌ Failed to create texture: {}\n", .{status});
            return error.TextureCreationFailed;
        }

        return MetalTextureSet{ .texture = texture };
    }

    /// Debug: inspect pixel buffer data (prints once per session)
    pub fn cpuInspectPixelBufferData(pixel_buffer: vtb.CVPixelBufferRef) !void {
        const State = struct {
            var printed: bool = false;
        };
        if (State.printed) return;
        State.printed = true;

        const width = vtb.CVPixelBufferGetWidth(pixel_buffer);
        const height = vtb.CVPixelBufferGetHeight(pixel_buffer);
        const bytes_per_row = vtb.CVPixelBufferGetBytesPerRow(pixel_buffer);
        const pixel_format = vtb.CVPixelBufferGetPixelFormatType(pixel_buffer);
        const format_bytes: [4]u8 = @bitCast(pixel_format);
        const bits_per_pixel = (bytes_per_row * 8) / width;

        std.debug.print("📊 Decoded: {d}x{d}, {s} ({d}-bit/pixel)\n", .{ width, height, &format_bytes, bits_per_pixel });
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

    // Request 64-bit RGBA half-float output (16-bit float per channel)
    var pixel_format_value: i32 = @bitCast(@as(u32, vtb.kCVPixelFormatType_64RGBAHalf));
    const pixel_format_num = vtb.CFNumberCreate(
        null,
        vtb.kCFNumberSInt32Type,
        &pixel_format_value,
    );
    defer if (pixel_format_num) |pf| vtb.CFRelease(pf);

    const keys = [_]?*const anyopaque{
        @ptrCast(vtb.kCVPixelBufferMetalCompatibilityKey),
        @ptrCast(vtb.kCVPixelBufferPixelFormatTypeKey),
    };
    const values = [_]?*const anyopaque{
        @ptrCast(vtb.kCFBooleanTrue),
        @ptrCast(pixel_format_num),
    };

    const pixel_attrs = vtb.CFDictionaryCreate(
        null,
        &keys[0],
        &values[0],
        2, // Now 2 key-value pairs
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
    var decompression_session: vtb.VTDecompressionSessionRef = null;
    const status = vtb.VTDecompressionSessionCreate(
        null, // allocator
        format_desc,
        null, // Let VideoToolbox choose decoder automatically
        pixel_attrs, // BGRA + Metal compatible output
        &callback_record,
        &decompression_session,
    );

    if (status != vtb.noErr) {
        std.debug.print("VTDecompressionSessionCreate failed: {d}\n", .{status});
        return error.CreateDecompressionSessionFailed;
    }

    // try getSupportedPixelFormats(session);

    return decompression_session.?;
}

/// DEBUG: Print supported pixel formats
fn getSupportedPixelFormats(session: vtb.VTDecompressionSessionRef) !void {
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
