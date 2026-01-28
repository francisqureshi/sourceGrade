const std = @import("std");
const media = @import("../media.zig");
const vtw = @import("videotoolbox_c.zig");

pub const MTLDeviceRef = vtw.MTLDeviceRef;

const Allocator = std.mem.Allocator;
const Io = std.Io;
pub const log = std.log.scoped(.videoToolBox);

/// For packed y416 format (kCVPixelFormatType_4444AYpCbCr16), we use a single RGBA16Unorm texture.
/// The 64-bit AYUV data maps to Metal's RGBA16 as: R=A, G=Y, B=Cb, A=Cr
pub const MetalTextureSet = struct {
    texture: vtw.CVMetalTextureRef, // Single packed AYUV texture

    pub fn getMetalTexture(self: *const MetalTextureSet) vtw.MTLTextureRef {
        return vtw.CVMetalTextureGetTexture(self.texture);
    }

    pub fn deinit(self: *MetalTextureSet) void {
        vtw.CFRelease(self.texture);
    }
};

pub const VideoToolboxDecoder = struct {
    session: vtw.VTDecompressionSessionRef,
    format_desc: vtw.CMVideoFormatDescriptionRef,
    frame_ctx: *FrameContext,
    source_media: *const media.SourceMedia, // Reference to clip
    texture_cache: vtw.CVMetalTextureCacheRef, // Metal texture cache for zero-copy textures
    metal_device: vtw.MTLDeviceRef, // Metal device

    pub fn init(
        source_media: *const media.SourceMedia,
        metal_device: vtw.MTLDeviceRef,
    ) !VideoToolboxDecoder {
        // Register professional video workflow decoders (ProRes, etc.)
        // This ensures we get native ProRes output formats without conversion
        const register_status = vtw.VTRegisterProfessionalVideoWorkflowVideoDecoders();
        if (register_status == vtw.noErr) {
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
        var texture_cache: vtw.CVMetalTextureCacheRef = undefined;
        const cache_status = vtw.CVMetalTextureCacheCreate(
            vtw.kCFAllocatorDefault,
            null, // cache attributes
            metal_device,
            null, // texture attributes
            &texture_cache,
        );
        if (cache_status != vtw.noErr) {
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

    pub fn decodeFrame(
        self: *VideoToolboxDecoder,
        frame_index: usize,
        scratch_allocator: Allocator,
    ) !DecodedFrame {
        self.frame_ctx.pixel_buffer = null;

        const frame_size = try self.source_media.getFrameSize(frame_index);
        // std.debug.print("\nFirst frame size: {d} bytes\n", .{frame_size});

        // Use scratch instead of self.source_media.mctx.allocator
        const encoded_frame_buffer = try scratch_allocator.alloc(u8, frame_size);
        // defer self.source_media.mctx.allocator.free(encoded_frame_buffer);

        // FIXME: is readFrame.... redundant...? As we pass this data to the BlockBuffer below???
        // Should we use a Io.Reader also ??
        _ = try self.source_media.readFrame(frame_index, encoded_frame_buffer);
        // std.debug.print("Read {d} bytes from frame 0\n", .{bytes_read});

        const block_buffer = try createBlockBuffer(encoded_frame_buffer);
        // std.debug.print("block_buffer: {*}\n", .{block_buffer});

        const timing_info = createSampleTimingInfo(frame_index, self.source_media);
        const sample_buffer = try createSampleBuffer(block_buffer, timing_info, self.format_desc);
        defer vtw.CFRelease(sample_buffer);

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
        pixel_buffer: vtw.CVPixelBufferRef,
    ) !MetalTextureSet {
        const width = vtw.CVPixelBufferGetWidth(pixel_buffer);
        const height = vtw.CVPixelBufferGetHeight(pixel_buffer);
        const pixel_format = vtw.CVPixelBufferGetPixelFormatType(pixel_buffer);

        // Debug: Print info once
        const State = struct {
            var printed: bool = false;
        };
        if (!State.printed) {
            State.printed = true;
            const bytes_per_row = vtw.CVPixelBufferGetBytesPerRow(pixel_buffer);
            const format_bytes: [4]u8 = @bitCast(pixel_format);
            const bits_per_pixel = (bytes_per_row * 8) / width;
            std.debug.print("\n🎬 Video texture: {d}x{d}, {s} ({d}-bit/pixel)\n", .{ width, height, &format_bytes, bits_per_pixel });
        }

        // Choose Metal pixel format based on CVPixelBuffer format
        const metal_format: vtw.MTLPixelFormat = switch (pixel_format) {
            vtw.kCVPixelFormatType_32BGRA => vtw.MTLPixelFormatBGRA8Unorm,
            vtw.kCVPixelFormatType_64RGBAHalf => vtw.MTLPixelFormatRGBA16Float, // Half-float
            vtw.kCVPixelFormatType_64ARGB => vtw.MTLPixelFormatRGBA16Unorm,
            vtw.kCVPixelFormatType_4444AYpCbCr16 => vtw.MTLPixelFormatRGBA16Unorm,
            else => {
                const format_bytes: [4]u8 = @bitCast(pixel_format);
                std.debug.print("Unknown pixel format: 0x{X:0>8} ('{s}')\n", .{ pixel_format, &format_bytes });
                return error.UnsupportedPixelFormat;
            },
        };

        var texture: vtw.CVMetalTextureRef = undefined;
        const status = vtw.CVMetalTextureCacheCreateTextureFromImage(
            vtw.kCFAllocatorDefault,
            self.texture_cache,
            pixel_buffer,
            null,
            metal_format,
            width,
            height,
            0,
            &texture,
        );

        if (status != vtw.noErr) {
            std.debug.print("❌ Failed to create texture: {}\n", .{status});
            return error.TextureCreationFailed;
        }

        return MetalTextureSet{ .texture = texture };
    }

    /// Debug: inspect pixel buffer data (prints once per session)
    pub fn cpuInspectPixelBufferData(pixel_buffer: vtw.CVPixelBufferRef) !void {
        const State = struct {
            var printed: bool = false;
        };
        if (State.printed) return;
        State.printed = true;

        const width = vtw.CVPixelBufferGetWidth(pixel_buffer);
        const height = vtw.CVPixelBufferGetHeight(pixel_buffer);
        const bytes_per_row = vtw.CVPixelBufferGetBytesPerRow(pixel_buffer);
        const pixel_format = vtw.CVPixelBufferGetPixelFormatType(pixel_buffer);
        const format_bytes: [4]u8 = @bitCast(pixel_format);
        const bits_per_pixel = (bytes_per_row * 8) / width;

        std.debug.print("📊 Decoded: {d}x{d}, {s} ({d}-bit/pixel)\n", .{ width, height, &format_bytes, bits_per_pixel });
    }

    pub fn deinit(self: *VideoToolboxDecoder) void {
        vtw.CFRelease(self.format_desc);
        vtw.VTDecompressionSessionInvalidate(self.session);
        vtw.CFRelease(self.session);
        vtw.CFRelease(self.texture_cache);
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
/// CoreVideo pixel buffer - decoded pixel data (GPU-backed, ref-counted)
const FrameContext = struct {
    pixel_buffer: ?vtw.CVPixelBufferRef,
};

pub const DecodedFrame = struct {
    pixel_buffer: vtw.CVPixelBufferRef,

    pub fn deinit(self: *const DecodedFrame) void {
        vtw.CFRelease(self.pixel_buffer);
    }
};

// Callback that receives decoded frames from VideoToolbox
export fn decompressionOutputCallback(
    decompressionOutputRefCon: ?*anyopaque,
    sourceFrameRefCon: ?*anyopaque,
    status: vtw.OSStatus,
    infoFlags: u32,
    imageBuffer: vtw.CVPixelBufferRef,
    presentationTimeStamp: vtw.CMTime,
    presentationDuration: vtw.CMTime,
) callconv(.c) void {
    if (status != vtw.noErr) {
        std.debug.print("❌ Decode callback error: {d}\n", .{status});
        return;
    }

    if (decompressionOutputRefCon) |ctx_ptr| {
        const ctx: *FrameContext = @ptrCast(@alignCast(ctx_ptr));
        ctx.pixel_buffer = imageBuffer;
        _ = vtw.CFRetain(imageBuffer); // Keep it alive beyond callback
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

fn createFormatDescription(source_media: *const media.SourceMedia) !vtw.CMVideoFormatDescriptionRef {
    var format_desc: vtw.CMVideoFormatDescriptionRef = null;

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
    const status = vtw.CMVideoFormatDescriptionCreateFromBigEndianImageDescriptionData(
        null,
        image_desc_data.ptr,
        image_desc_data.len,
        vtw.CFStringGetSystemEncoding(),
        null, // NULL = QuickTimeMovie flavor (default)
        &format_desc,
    );

    if (status != vtw.noErr) {
        std.debug.print("CMVideoFormatDescriptionCreateFromBigEndianImageDescriptionData failed: {d}\n", .{status});
        return error.CreateFormatDescriptionFailed;
    }
    return format_desc.?;
}

fn createDecompressionSession(
    format_desc: vtw.CMVideoFormatDescriptionRef,
    frame_ctx: *FrameContext,
) !vtw.VTDecompressionSessionRef {

    // Request 64-bit RGBA half-float output (16-bit float per channel)
    var pixel_format_value: i32 = @bitCast(@as(u32, vtw.kCVPixelFormatType_64RGBAHalf));
    const pixel_format_num = vtw.CFNumberCreate(
        null,
        vtw.kCFNumberSInt32Type,
        &pixel_format_value,
    );
    defer if (pixel_format_num) |pf| vtw.CFRelease(pf);

    const keys = [_]?*const anyopaque{
        @ptrCast(vtw.kCVPixelBufferMetalCompatibilityKey),
        @ptrCast(vtw.kCVPixelBufferPixelFormatTypeKey),
    };
    const values = [_]?*const anyopaque{
        @ptrCast(vtw.kCFBooleanTrue),
        @ptrCast(pixel_format_num),
    };

    const pixel_attrs = vtw.CFDictionaryCreate(
        null,
        &keys[0],
        &values[0],
        2, // Now 2 key-value pairs
        null,
        null,
    );
    defer vtw.CFRelease(pixel_attrs);

    // Create callback record
    const callback_record = vtw.VTDecompressionOutputCallbackRecord{
        .decompressionOutputCallback = decompressionOutputCallback,
        .decompressionOutputRefCon = frame_ctx,
    };

    // Create decompression session
    var decompression_session: vtw.VTDecompressionSessionRef = null;
    const status = vtw.VTDecompressionSessionCreate(
        null, // allocator
        format_desc,
        null, // Let VideoToolbox choose decoder automatically
        pixel_attrs, // BGRA + Metal compatible output
        &callback_record,
        &decompression_session,
    );

    if (status != vtw.noErr) {
        std.debug.print("VTDecompressionSessionCreate failed: {d}\n", .{status});
        return error.CreateDecompressionSessionFailed;
    }

    // try getSupportedPixelFormats(session);

    return decompression_session.?;
}

/// DEBUG: Print supported pixel formats
fn getSupportedPixelFormats(session: vtw.VTDecompressionSessionRef) !void {
    var props: ?*anyopaque = null;
    const prop_status = vtw.VTSessionCopyProperty(
        session,
        vtw.kVTDecompressionPropertyKey_SupportedPixelFormatsOrderedByQuality,
        null,
        &props,
    );
    if (prop_status == vtw.noErr and props != null) {
        std.debug.print("\n📋 Supported Pixel Formats (ordered by quality):\n", .{});
        const count = vtw.CFArrayGetCount(@ptrCast(props));
        std.debug.print("   Count: {}\n", .{count});
        for (0..@intCast(count)) |i| {
            const num = vtw.CFArrayGetValueAtIndex(@ptrCast(props), @intCast(i));
            var format: u32 = 0;
            _ = vtw.CFNumberGetValue(@ptrCast(@alignCast(@constCast(num))), vtw.kCFNumberSInt32Type, &format);
            const bytes = @as([4]u8, @bitCast(format));
            std.debug.print("   [{}] 0x{X:0>8} ('{c}{c}{c}{c}')\n", .{ i, format, bytes[3], bytes[2], bytes[1], bytes[0] });
        }
        vtw.CFRelease(props.?);
    }
}

fn createBlockBuffer(frame_data: []u8) !vtw.CMBlockBufferRef {
    var block_buffer: vtw.CMBlockBufferRef = null;

    const status = vtw.CMBlockBufferCreateWithMemoryBlock(
        vtw.kCFAllocatorDefault,
        frame_data.ptr,
        frame_data.len,
        vtw.kCFAllocatorNull,
        null,
        0,
        frame_data.len,
        0,
        &block_buffer,
    );

    if (status != vtw.noErr) {
        return error.CreateBlockBufferFailed;
    }

    return block_buffer.?;
}

fn createSampleTimingInfo(
    frame_index: usize,
    source_media: *const media.SourceMedia,
) vtw.CMSampleTimingInfo {
    // PTS = frame_index × frame_duration / timescale
    // For frame 0: PTS = 0
    const pts_value: i64 = @as(i64, @intCast(frame_index)) * @as(i64, @intCast(source_media.frame_rate.original.den));
    const pts = vtw.CMTimeMake(pts_value, @as(i32, @intCast(source_media.frame_rate.original.num)));

    // Duration = frame_duration / timescale
    const duration = vtw.CMTimeMake(
        @as(i64, @intCast(source_media.frame_rate.original.den)),
        @as(i32, @intCast(source_media.frame_rate.original.num)),
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
    block_buffer: vtw.CMBlockBufferRef,
    timing_info: vtw.CMSampleTimingInfo,
    format_desc: vtw.CMVideoFormatDescriptionRef,
) !vtw.CMSampleBufferRef {
    var sample_buffer: vtw.CMSampleBufferRef = null;

    const status = vtw.CMSampleBufferCreateReady(
        vtw.kCFAllocatorDefault, // allocator
        block_buffer, // dataBuffer (our block buffer)
        format_desc, // formatDescription
        1, // numSamples (1 frame)
        1, // numSampleTimingEntries
        &[_]vtw.CMSampleTimingInfo{timing_info}, // sampleTimingArray
        0, // numSampleSizeEntries
        null, // sampleSizeArray
        &sample_buffer, // sampleBufferOut
    );

    if (status != vtw.noErr) {
        return error.CreateSampleBufferFailed;
    }

    return sample_buffer.?;
}

fn decompress(
    session: vtw.VTDecompressionSessionRef,
    sample_buffer: vtw.CMSampleBufferRef,
) !void {
    const status = vtw.VTDecompressionSessionDecodeFrame(
        session,
        sample_buffer,
        0, // decodeFlags: no special options
        null, // sourceFrameRefCon: context for callback
        null, // infoFlagsOut: output flags
    );

    if (status != vtw.noErr) {
        std.debug.print("VTDecompressionSessionDecodeFrame failed: {d}\n", .{status});
        return error.DecodeFrameFailed;
    }

    // Wait for decoder to finish (blocks until callback completes)
    const wait_status = vtw.VTDecompressionSessionWaitForAsynchronousFrames(session);
    if (wait_status != vtw.noErr) {
        std.debug.print("VTDecompressionSessionWaitForAsynchronousFrames failed: {d}\n", .{wait_status});
        return error.DecoderWaitFailed;
    }
}

pub fn decode(source_media: *const media.SourceMedia) !void {
    std.debug.print("\n=== VideoToolbox Tests ===\n", .{});

    const format_desc = try createFormatDescription(source_media);
    defer vtw.CFRelease(format_desc);

    // Check Fmt Description
    try verifyFmtDes(format_desc);

    // Check if hardware decode is supported for this codec
    const codec_type = vtw.CMFormatDescriptionGetMediaSubType(format_desc);
    const hw_supported = vtw.VTIsHardwareDecodeSupported(codec_type);
    std.debug.print("Hardware decode supported: {}\n", .{hw_supported != 0});

    var frame_ctx = FrameContext{ .pixel_buffer = null };

    const session = try createDecompressionSession(format_desc, &frame_ctx);
    defer {
        vtw.VTDecompressionSessionInvalidate(session);
        vtw.CFRelease(session);
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
        vtw.CFRelease(pb); // Release when done
    }

    defer vtw.CFRelease(sample_buffer);

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
fn verifyFmtDes(format_desc: vtw.CMVideoFormatDescriptionRef) !void {
    std.debug.print("Format description created: {*}\n", .{format_desc});

    // Verify the codec type
    const codec_type = vtw.CMFormatDescriptionGetMediaSubType(format_desc);
    const codec_bytes: [4]u8 = @bitCast(codec_type);
    std.debug.print("   Codec FourCC: 0x{X:0>8} ('{s}')\n", .{
        codec_type,
        &codec_bytes,
    });

    // Verify dimensions
    const dims = vtw.CMVideoFormatDescriptionGetDimensions(format_desc);
    std.debug.print("   Dimensions: {d}x{d}\n", .{ dims.width, dims.height });
}
