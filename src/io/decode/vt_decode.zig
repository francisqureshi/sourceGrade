const std = @import("std");
const media = @import("../media.zig");
const vtb = @import("videotoolbox_c.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
pub const log = std.log.scoped(.videoToolBox);

const VideoToolboxError = error{
    CreateFormatDescriptionFailed,
};

pub fn decode(SourceMedia: media.SourceMedia) !void {
    std.debug.print("\n=== VideoToolbox Tests ===\n", .{});

    var format_desc: vtb.CMVideoFormatDescriptionRef = null;

    const status = vtb.CMVideoFormatDescriptionCreate(null, @bitCast(SourceMedia.codec[0..4].*), @intCast(SourceMedia.resolution.width), @intCast(SourceMedia.resolution.height), null, &format_desc);

    if (status != vtb.noErr) {
        std.debug.print("CMVideoFormatDescriptionCreate failed: {d}\n", .{status});
        return error.CreateFormatDescriptionFailed;
    }

    std.debug.print("✅ Format description created: {*}\n", .{format_desc});

    // // Verify the codec type
    // const codec_type = vtb.CMFormatDescriptionGetMediaSubType(format_desc);
    // const codec_bytes: [4]u8 = @bitCast(codec_type);
    // std.debug.print("   Codec FourCC: 0x{X:0>8} ('{s}')\n", .{
    //     codec_type,
    //     &codec_bytes,
    // });
    //
    // // Verify dimensions
    // const dims = vtb.CMVideoFormatDescriptionGetDimensions(format_desc);
    // std.debug.print("   Dimensions: {d}x{d}\n", .{ dims.width, dims.height });

    defer vtb.CFRelease(format_desc);
}
