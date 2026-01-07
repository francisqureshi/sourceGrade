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

    const status =
        vtb.CMVideoFormatDescriptionCreate(
            null,
            @bitCast(source_media.codec[0..4].*),
            @intCast(source_media.resolution.width),
            @intCast(source_media.resolution.height),
            null,
            &format_desc,
        );

    if (status != vtb.noErr) {
        std.debug.print("CMVideoFormatDescriptionCreate failed: {d}\n", .{status});
        return error.CreateFormatDescriptionFailed;
    }
    return format_desc.?; // Return the non-null value
}

fn createDecompressionSession(format_desc: vtb.CMVideoFormatDescriptionRef) !vtb.VTDecompressionSessionRef {
    // Create CFNumber for pixel format
    var pixel_format: u32 = vtb.kCVPixelFormatType_32BGRA;
    const pixel_format_number = vtb.CFNumberCreate(
        null,
        vtb.kCFNumberSInt32Type,
        &pixel_format,
    );
    defer vtb.CFRelease(pixel_format_number);

    // Create arrays for dictionary
    const keys = [_]?*const anyopaque{
        @ptrCast(&vtb.kCVPixelBufferPixelFormatTypeKey),
        @ptrCast(&vtb.kCVPixelBufferMetalCompatibilityKey),
    };
    const values = [_]?*const anyopaque{
        @ptrCast(pixel_format_number),
        @ptrCast(vtb.kCFBooleanTrue),
    };

    const pixel_attrs = vtb.CFDictionaryCreate(
        null,
        &keys[0],
        &values[0],
        2,
        null,
        null,
    );
    defer vtb.CFRelease(pixel_attrs);

    // Create callback record
    const callback_record = vtb.VTDecompressionOutputCallbackRecord{
        .decompressionOutputCallback = decompressionOutputCallback,
        .decompressionOutputRefCon = null,
    };

    // Create decompression session
    var session: vtb.VTDecompressionSessionRef = null;
    const status = vtb.VTDecompressionSessionCreate(
        null, // allocator
        format_desc,
        null, // Let VideoToolbox choose decoder automatically
        pixel_attrs,
        &callback_record,
        &session,
    );

    if (status != vtb.noErr) {
        std.debug.print("VTDecompressionSessionCreate failed: {d}\n", .{status});
        return error.CreateDecompressionSessionFailed;
    }

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
    defer vtb.VTDecompressionSessionInvalidate(session);
    defer vtb.CFRelease(session);
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
