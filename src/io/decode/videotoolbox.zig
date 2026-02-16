const std = @import("std");
const decoder = @import("../decode/decoder.zig");
const media = @import("../media.zig");
const c = @import("c.zig");

pub const MTLDeviceRef = c.MTLDeviceRef;

const Allocator = std.mem.Allocator;
const Io = std.Io;
pub const log = std.log.scoped(.videoToolBox);

const VideoToolboxError = error{
    CreateFormatDescriptionFailed,
    CreateDecompressionSessionFailed,
    CreateBlockBufferFailed,
    CreateSampleBufferFailed,
    DecodeFrameFailed,
    DecoderWaitFailed,
    TextureCreationFailed,
};

/// For packed y416 format (kCVPixelFormatType_4444AYpCbCr16), we use a single RGBA16Unorm texture.
/// The 64-bit AYUV data maps to Metal's RGBA16 as: R=A, G=Y, B=Cb, A=Cr
pub const MetalTextureSet = struct {
    texture: c.CVMetalTextureRef, // Single packed AYUV texture

    /// Returns the underlying MTLTexture for binding to Metal render pipelines.
    /// The texture remains valid as long as this MetalTextureSet is alive.
    pub fn getMetalTexture(self: *const MetalTextureSet) c.MTLTextureRef {
        return c.CVMetalTextureGetTexture(self.texture);
    }

    /// Releases the CVMetalTexture reference.
    /// The underlying Metal texture becomes invalid after this call.
    pub fn deinit(self: *MetalTextureSet) void {
        c.CFRelease(self.texture);
    }
};

/// macOS VideoToolbox hardware decoder wrapper.
/// Uses Apple's hardware-accelerated ProRes/H.264/HEVC decoding via VTDecompressionSession.
/// Outputs GPU-backed CVPixelBuffers for zero-copy Metal rendering.
pub const Decoder = struct {
    session: c.VTDecompressionSessionRef,
    format_desc: c.CMVideoFormatDescriptionRef,
    frame_ctx: *FrameContext,
    source_media: *const media.SourceMedia, // Reference to clip
    texture_cache: c.CVMetalTextureCacheRef, // Metal texture cache for zero-copy textures
    metal_device: c.MTLDeviceRef, // Metal device

    /// Creates a VideoToolbox decoder for the given source media.
    /// Attempts to registers professional codecs (ProRes), creates format description from stsd atom,
    /// sets up decompression session with Metal-compatible output, and creates texture cache.
    pub fn init(
        source_media: *const media.SourceMedia,
        metal_device: c.MTLDeviceRef,
    ) !Decoder {
        // Register professional video workflow decoders (ProRes, etc.)
        // This ensures we get native ProRes output formats without conversion
        const register_status = c.VTRegisterProfessionalVideoWorkflowVideoDecoders();
        if (register_status == c.noErr) {
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
        var texture_cache: c.CVMetalTextureCacheRef = undefined;
        const cache_status = c.CVMetalTextureCacheCreate(
            c.kCFAllocatorDefault,
            null, // cache attributes
            metal_device,
            null, // texture attributes
            &texture_cache,
        );
        if (cache_status != c.noErr) {
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

    /// Returns this VideoToolbox decoder as the abstract Decoder interface.
    pub fn asDecoder(self: *Decoder) decoder.Decoder {
        return .{
            .impl = @ptrCast(self),
            .decode_frame_fn = decodeFrameWrapper,
            .deinit_fn = deinitWrapper,
        };
    }

    /// Calls videotoolbox.zig Decoder's deinit()
    fn deinitWrapper(impl: *anyopaque) void {
        const self: *Decoder = @ptrCast(@alignCast(impl));
        return self.deinit();
    }

    /// Calls videotoolbox.zig Decoder's decodeFrame()
    fn decodeFrameWrapper(
        impl: *anyopaque,
        frame_idx: usize,
        allocator: Allocator,
    ) anyerror!decoder.DecodedFrame {
        const self: *Decoder = @ptrCast(@alignCast(impl));
        return self.decodeFrame(frame_idx, allocator);
    }

    /// Decodes a single frame by index, returning a platform-agnostic DecodedFrame.
    /// Reads compressed data from source media, wraps in CoreMedia buffers,
    /// submits to VTDecompressionSession, and returns GPU-backed CVPixelBuffer.
    /// The scratch_allocator is used for temporary compressed frame data.
    pub fn decodeFrame(
        self: *Decoder,
        frame_index: usize,
        scratch_allocator: Allocator,
    ) !decoder.DecodedFrame {
        self.frame_ctx.pixel_buffer = null;

        const frame_size = try self.source_media.getFrameSize(frame_index);
        // std.debug.print("\nFirst frame size: {d} bytes\n", .{frame_size});

        // Use scratch instead of self.source_media.mctx.allocator
        std.debug.print("Requesting: {d} bytes\n", .{frame_size});
        const encoded_frame_buffer = try scratch_allocator.alloc(u8, frame_size);

        const compressed_frame_size = try self.source_media.readFrame(frame_index, encoded_frame_buffer);

        // Wrap encoded frame data to Core Media BlockBuffer below
        const block_buffer = try createBlockBuffer(encoded_frame_buffer);

        const timing_info = createSampleTimingInfo(frame_index, self.source_media);
        const sample_buffer = try createSampleBuffer(block_buffer, timing_info, self.format_desc);
        defer c.CFRelease(sample_buffer);

        //  Decode the frame
        try decompress(self.session, sample_buffer);

        // Now frame_ctx.pixel_buffer contains the decoded frame
        if (self.frame_ctx.pixel_buffer) |pb| {
            // // Debug decoded data via CPU:
            // try cpuInspectPixelBufferData(pb); // CPU PixBuf check
            const decoded_frame_size = c.CVPixelBufferGetDataSize(pb);

            return decoder.DecodedFrame{
                .platform_handle = pb,
                .width = c.CVPixelBufferGetWidth(pb),
                .height = c.CVPixelBufferGetHeight(pb),
                .compressed_size = compressed_frame_size,
                .decoded_size = decoded_frame_size,
                .deinit_fn = releasePixelBuffer,
            };
        } else {
            return error.DecodeFrameFailed;
        }
    }

    /// Creates Metal texture from CVPixelBuffer.
    /// Now supports BGRA format (VideoToolbox converts YCbCr to RGB for us)
    pub fn createMetalTextures(
        self: *const Decoder,
        pixel_buffer: c.CVPixelBufferRef,
    ) !MetalTextureSet {
        const width = c.CVPixelBufferGetWidth(pixel_buffer);
        const height = c.CVPixelBufferGetHeight(pixel_buffer);
        const pixel_format = c.CVPixelBufferGetPixelFormatType(pixel_buffer);

        // Debug: Print info once
        const State = struct {
            var printed: bool = false;
        };
        if (!State.printed) {
            State.printed = true;
            const bytes_per_row = c.CVPixelBufferGetBytesPerRow(pixel_buffer);
            const format_bytes: [4]u8 = @bitCast(pixel_format);
            const bits_per_pixel = (bytes_per_row * 8) / width;
            std.debug.print("\n🎬 Video texture: {d}x{d}, {s} ({d}-bit/pixel)\n", .{ width, height, &format_bytes, bits_per_pixel });
        }

        // Choose Metal pixel format based on CVPixelBuffer format
        const metal_format: c.MTLPixelFormat = switch (pixel_format) {
            c.kCVPixelFormatType_32BGRA => c.MTLPixelFormatBGRA8Unorm,
            c.kCVPixelFormatType_64RGBAHalf => c.MTLPixelFormatRGBA16Float, // Half-float
            c.kCVPixelFormatType_64ARGB => c.MTLPixelFormatRGBA16Unorm,
            c.kCVPixelFormatType_4444AYpCbCr16 => c.MTLPixelFormatRGBA16Unorm,
            else => {
                const format_bytes: [4]u8 = @bitCast(pixel_format);
                std.debug.print("Unknown pixel format: 0x{X:0>8} ('{s}')\n", .{ pixel_format, &format_bytes });
                return error.UnsupportedPixelFormat;
            },
        };

        var texture: c.CVMetalTextureRef = undefined;
        const status = c.CVMetalTextureCacheCreateTextureFromImage(
            c.kCFAllocatorDefault,
            self.texture_cache,
            pixel_buffer,
            null,
            metal_format,
            width,
            height,
            0,
            &texture,
        );

        if (status != c.noErr) {
            std.debug.print(" Failed to create texture: {}\n", .{status});
            return error.TextureCreationFailed;
        }

        return MetalTextureSet{ .texture = texture };
    }

    /// Debug: inspect pixel buffer data (prints once per session)
    pub fn cpuInspectPixelBufferData(pixel_buffer: c.CVPixelBufferRef) !void {
        const State = struct {
            var printed: bool = false;
        };
        if (State.printed) return;
        State.printed = true;

        const width = c.CVPixelBufferGetWidth(pixel_buffer);
        const height = c.CVPixelBufferGetHeight(pixel_buffer);
        const bytes_per_row = c.CVPixelBufferGetBytesPerRow(pixel_buffer);
        const pixel_format = c.CVPixelBufferGetPixelFormatType(pixel_buffer);
        const format_bytes: [4]u8 = @bitCast(pixel_format);
        const bits_per_pixel = (bytes_per_row * 8) / width;

        std.debug.print("Decoded: {d}x{d}, {s} ({d}-bit/pixel)\n", .{ width, height, &format_bytes, bits_per_pixel });
    }

    /// Releases all VideoToolbox resources: format description, decompression session,
    /// texture cache, and frame context. Must be called when decoder is no longer needed.
    pub fn deinit(self: *Decoder) void {
        c.CFRelease(self.format_desc);
        c.VTDecompressionSessionInvalidate(self.session);
        c.CFRelease(self.session);
        c.CFRelease(self.texture_cache);
        self.source_media.mctx.allocator.destroy(self.frame_ctx);
    }
};

/// CoreVideo pixel buffer - decoded pixel data (GPU-backed, ref-counted)
const FrameContext = struct {
    pixel_buffer: ?c.CVPixelBufferRef,
};

/// Cleanup function for DecodedFrame's deinit_fn.
/// Releases the CVPixelBuffer via CoreFoundation reference counting.
/// Called automatically when DecodedFrame.deinit() is invoked.
fn releasePixelBuffer(handle: *anyopaque) void {
    c.CFRelease(handle);
}

// FIXME: Deprecated for abstracted version via decoder.zig
// pub const DecodedFrame = struct {
//     pixel_buffer: c.CVPixelBufferRef,
//     compressed_frame_size: usize,
//     decoded_frame_size: usize,
//     pub fn deinit(self: *const DecodedFrame) void {
//         c.CFRelease(self.pixel_buffer);
//     }
// };

/// VideoToolbox decompression callback - receives decoded frames asynchronously.
/// Called by VTDecompressionSession after each frame is decoded.
/// Stores the CVPixelBuffer in FrameContext and retains it for later use.
export fn decompressionOutputCallback(
    decompressionOutputRefCon: ?*anyopaque,
    sourceFrameRefCon: ?*anyopaque,
    status: c.OSStatus,
    infoFlags: u32,
    imageBuffer: c.CVPixelBufferRef,
    presentationTimeStamp: c.CMTime,
    presentationDuration: c.CMTime,
) callconv(.c) void {
    if (status != c.noErr) {
        std.debug.print("Decode callback error: {d}\n", .{status});
        return;
    }

    if (decompressionOutputRefCon) |ctx_ptr| {
        const ctx: *FrameContext = @ptrCast(@alignCast(ctx_ptr));
        ctx.pixel_buffer = imageBuffer;
        _ = c.CFRetain(imageBuffer); // Keep it alive beyond callback
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

/// Creates CMVideoFormatDescription from the stsd (sample description) atom.
/// Parses the QuickTime ImageDescription data embedded in source media's stsd_data.
/// This tells VideoToolbox the codec type, dimensions, and color info.
fn createFormatDescription(source_media: *const media.SourceMedia) !c.CMVideoFormatDescriptionRef {
    var format_desc: c.CMVideoFormatDescriptionRef = null;

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
    const status = c.CMVideoFormatDescriptionCreateFromBigEndianImageDescriptionData(
        null,
        image_desc_data.ptr,
        image_desc_data.len,
        c.CFStringGetSystemEncoding(),
        null, // NULL = QuickTimeMovie flavor (default)
        &format_desc,
    );

    if (status != c.noErr) {
        std.debug.print("CMVideoFormatDescriptionCreateFromBigEndianImageDescriptionData failed: {d}\n", .{status});
        return error.CreateFormatDescriptionFailed;
    }
    return format_desc.?;
}

/// Creates VTDecompressionSession with Metal-compatible pixel buffer output.
/// Configures 64-bit RGBA half-float format (kCVPixelFormatType_64RGBAHalf) for HDR support.
/// Sets up callback to receive decoded frames into the provided FrameContext.
fn createDecompressionSession(
    format_desc: c.CMVideoFormatDescriptionRef,
    frame_ctx: *FrameContext,
) !c.VTDecompressionSessionRef {

    // Request 64-bit RGBA half-float output (16-bit float per channel)
    var pixel_format_value: i32 = @bitCast(@as(u32, c.kCVPixelFormatType_64RGBAHalf));
    const pixel_format_num = c.CFNumberCreate(
        null,
        c.kCFNumberSInt32Type,
        &pixel_format_value,
    );
    defer if (pixel_format_num) |pf| c.CFRelease(pf);

    const keys = [_]?*const anyopaque{
        @ptrCast(c.kCVPixelBufferMetalCompatibilityKey),
        @ptrCast(c.kCVPixelBufferPixelFormatTypeKey),
    };
    const values = [_]?*const anyopaque{
        @ptrCast(c.kCFBooleanTrue),
        @ptrCast(pixel_format_num),
    };

    const pixel_attrs = c.CFDictionaryCreate(
        null,
        &keys[0],
        &values[0],
        2, // Now 2 key-value pairs
        null,
        null,
    );
    defer c.CFRelease(pixel_attrs);

    // Create callback record
    const callback_record = c.VTDecompressionOutputCallbackRecord{
        .decompressionOutputCallback = decompressionOutputCallback,
        .decompressionOutputRefCon = frame_ctx,
    };

    // Create decompression session
    var decompression_session: c.VTDecompressionSessionRef = null;
    const status = c.VTDecompressionSessionCreate(
        null, // allocator
        format_desc,
        null, // Let VideoToolbox choose decoder automatically
        pixel_attrs, // BGRA + Metal compatible output
        &callback_record,
        &decompression_session,
    );

    if (status != c.noErr) {
        std.debug.print("VTDecompressionSessionCreate failed: {d}\n", .{status});
        return error.CreateDecompressionSessionFailed;
    }

    // try getSupportedPixelFormats(session);

    return decompression_session.?;
}

/// Wraps raw compressed frame data in a CMBlockBuffer for VideoToolbox.
/// The block buffer references the existing memory without copying.
/// Must remain valid until decoding completes.
fn createBlockBuffer(frame_data: []u8) !c.CMBlockBufferRef {
    var block_buffer: c.CMBlockBufferRef = null;

    const status = c.CMBlockBufferCreateWithMemoryBlock(
        c.kCFAllocatorDefault,
        frame_data.ptr,
        frame_data.len,
        c.kCFAllocatorNull,
        null,
        0,
        frame_data.len,
        0,
        &block_buffer,
    );

    if (status != c.noErr) {
        return error.CreateBlockBufferFailed;
    }

    return block_buffer.?;
}

/// Builds timing info (PTS, DTS, duration) for a frame.
/// Uses source media's frame rate to calculate presentation timestamp.
/// For intraframe codecs like ProRes, DTS equals PTS.
fn createSampleTimingInfo(
    frame_index: usize,
    source_media: *const media.SourceMedia,
) c.CMSampleTimingInfo {
    // PTS = frame_index × frame_duration / timescale
    // For frame 0: PTS = 0
    const pts_value: i64 = @as(i64, @intCast(frame_index)) * @as(i64, @intCast(source_media.frame_rate.original.den));
    const pts = c.CMTimeMake(pts_value, @as(i32, @intCast(source_media.frame_rate.original.num)));

    // Duration = frame_duration / timescale
    const duration = c.CMTimeMake(
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

/// Combines block buffer, timing, and format into a CMSampleBuffer.
/// This is the final package VideoToolbox needs to decode a frame.
/// Contains one sample (frame) ready for decompression.
fn createSampleBuffer(
    block_buffer: c.CMBlockBufferRef,
    timing_info: c.CMSampleTimingInfo,
    format_desc: c.CMVideoFormatDescriptionRef,
) !c.CMSampleBufferRef {
    var sample_buffer: c.CMSampleBufferRef = null;

    const status = c.CMSampleBufferCreateReady(
        c.kCFAllocatorDefault, // allocator
        block_buffer, // dataBuffer (our block buffer)
        format_desc, // formatDescription
        1, // numSamples (1 frame)
        1, // numSampleTimingEntries
        &[_]c.CMSampleTimingInfo{timing_info}, // sampleTimingArray
        0, // numSampleSizeEntries
        null, // sampleSizeArray
        &sample_buffer, // sampleBufferOut
    );

    if (status != c.noErr) {
        return error.CreateSampleBufferFailed;
    }

    return sample_buffer.?;
}

/// Submits sample buffer to VideoToolbox for decoding and waits for completion.
/// Triggers decompressionOutputCallback with the decoded CVPixelBuffer.
/// Blocks until the frame is fully decoded (synchronous decode).
fn decompress(
    session: c.VTDecompressionSessionRef,
    sample_buffer: c.CMSampleBufferRef,
) !void {
    const status = c.VTDecompressionSessionDecodeFrame(
        session,
        sample_buffer,
        0, // decodeFlags: no special options
        null, // sourceFrameRefCon: context for callback
        null, // infoFlagsOut: output flags
    );

    if (status != c.noErr) {
        std.debug.print("VTDecompressionSessionDecodeFrame failed: {d}\n", .{status});
        return error.DecodeFrameFailed;
    }

    // Wait for decoder to finish (blocks until callback completes)
    const wait_status = c.VTDecompressionSessionWaitForAsynchronousFrames(session);
    if (wait_status != c.noErr) {
        std.debug.print("VTDecompressionSessionWaitForAsynchronousFrames failed: {d}\n", .{wait_status});
        return error.DecoderWaitFailed;
    }
}

/// Standalone test function for VideoToolbox decoding.
/// Decodes frame 0 and prints debug info. Used during development.
/// Does not require Metal device - cannot create textures.
pub fn decode(source_media: *const media.SourceMedia) !void {
    std.debug.print("\n=== VideoToolbox Tests ===\n", .{});

    const format_desc = try createFormatDescription(source_media);
    defer c.CFRelease(format_desc);

    // Check Fmt Description
    try verifyFmtDes(format_desc);

    // Check if hardware decode is supported for this codec
    const codec_type = c.CMFormatDescriptionGetMediaSubType(format_desc);
    const hw_supported = c.VTIsHardwareDecodeSupported(codec_type);
    std.debug.print("Hardware decode supported: {}\n", .{hw_supported != 0});

    var frame_ctx = FrameContext{ .pixel_buffer = null };

    const session = try createDecompressionSession(format_desc, &frame_ctx);
    defer {
        c.VTDecompressionSessionInvalidate(session);
        c.CFRelease(session);
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
        c.CFRelease(pb); // Release when done
    }

    defer c.CFRelease(sample_buffer);

    defer source_media.mctx.allocator.free(buffer);

    //  Check agian after defers
    if (frame_ctx.pixel_buffer) |pb| {
        // vtb.CFRelease(pb); // Release when done
        std.debug.print("Check agian after CFRealease(pb) + defers....\nGot pixel buffer: {*}\n", .{pb});
    }
}

/// DEBUG: Print supported pixel formats
fn getSupportedPixelFormats(session: c.VTDecompressionSessionRef) !void {
    var props: ?*anyopaque = null;
    const prop_status = c.VTSessionCopyProperty(
        session,
        c.kVTDecompressionPropertyKey_SupportedPixelFormatsOrderedByQuality,
        null,
        &props,
    );
    if (prop_status == c.noErr and props != null) {
        std.debug.print("\n📋 Supported Pixel Formats (ordered by quality):\n", .{});
        const count = c.CFArrayGetCount(@ptrCast(props));
        std.debug.print("   Count: {}\n", .{count});
        for (0..@intCast(count)) |i| {
            const num = c.CFArrayGetValueAtIndex(@ptrCast(props), @intCast(i));
            var format: u32 = 0;
            _ = c.CFNumberGetValue(@ptrCast(@alignCast(@constCast(num))), c.kCFNumberSInt32Type, &format);
            const bytes = @as([4]u8, @bitCast(format));
            std.debug.print("   [{}] 0x{X:0>8} ('{c}{c}{c}{c}')\n", .{ i, format, bytes[3], bytes[2], bytes[1], bytes[0] });
        }
        c.CFRelease(props.?);
    }
}

/// Debug: Prints format description details (codec FourCC, dimensions).
/// Useful for verifying stsd parsing worked correctly.
fn verifyFmtDes(format_desc: c.CMVideoFormatDescriptionRef) !void {
    std.debug.print("Format description created: {*}\n", .{format_desc});

    // Verify the codec type
    const codec_type = c.CMFormatDescriptionGetMediaSubType(format_desc);
    const codec_bytes: [4]u8 = @bitCast(codec_type);
    std.debug.print("   Codec FourCC: 0x{X:0>8} ('{s}')\n", .{
        codec_type,
        &codec_bytes,
    });

    // Verify dimensions
    const dims = c.CMVideoFormatDescriptionGetDimensions(format_desc);
    std.debug.print("   Dimensions: {d}x{d}\n", .{ dims.width, dims.height });
}
