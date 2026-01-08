const std = @import("std");
const media = @import("../media.zig");
const vtb = @import("videotoolbox_c.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
pub const log = std.log.scoped(.videoToolBox);

const VideoToolboxError = error{
    CreateFormatDescriptionFailed,
    CreateDecompressionSessionFailed,
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
    _ = decompressionOutputRefCon;
    _ = sourceFrameRefCon;
    _ = infoFlags;
    _ = presentationTimeStamp;
    _ = presentationDuration;

    if (status != vtb.noErr) {
        std.debug.print("❌ Decode callback error: {d}\n", .{status});
        return;
    }

    std.debug.print("✅ Decode callback received frame: {*}\n", .{imageBuffer});
}

fn createFormatDescription(source_media: media.SourceMedia) !vtb.CMVideoFormatDescriptionRef {
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

    std.debug.print("stsd_data size: {d} bytes, image_desc size: {d} bytes\n", .{ source_media.stsd_data.len, image_desc_data.len });
    std.debug.print("First 16 bytes of image_desc: ", .{});
    for (image_desc_data[0..@min(16, image_desc_data.len)]) |b| {
        std.debug.print("{X:0>2} ", .{b});
    }
    std.debug.print("\n", .{});

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

fn createDecompressionSession(format_desc: vtb.CMVideoFormatDescriptionRef) !vtb.VTDecompressionSessionRef {
    // Create callback record
    const callback_record = vtb.VTDecompressionOutputCallbackRecord{
        .decompressionOutputCallback = decompressionOutputCallback,
        .decompressionOutputRefCon = null,
    };

    // Create decompression session (use null for pixel_attrs for now to test)
    var session: vtb.VTDecompressionSessionRef = null;
    const status = vtb.VTDecompressionSessionCreate(
        null, // allocator
        format_desc,
        null, // Let VideoToolbox choose decoder automatically
        null, // null pixel attrs for testing
        &callback_record,
        &session,
    );

    if (status != vtb.noErr) {
        std.debug.print("VTDecompressionSessionCreate failed: {d}\n", .{status});
        return error.CreateDecompressionSessionFailed;
    }

    std.debug.print("✅ Decompression session created successfully!\n", .{});
    return session.?;
}

pub fn decode(source_media: media.SourceMedia) !void {
    std.debug.print("\n=== VideoToolbox Tests ===\n", .{});

    const format_desc = try createFormatDescription(source_media);
    defer vtb.CFRelease(format_desc);

    // Check Fmt Description
    try verifyFmtDes(format_desc);

    // Check if hardware decode is supported for this codec
    const codec_type = vtb.CMFormatDescriptionGetMediaSubType(format_desc);
    const hw_supported = vtb.VTIsHardwareDecodeSupported(codec_type);
    std.debug.print("Hardware decode supported: {}\n", .{hw_supported != 0});

    const session = try createDecompressionSession(format_desc);
    defer {
        vtb.VTDecompressionSessionInvalidate(session);
        vtb.CFRelease(session);
    }

    std.debug.print("🎉 Phase 4.3 Complete! VTDecompressionSession created successfully!\n", .{});
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
