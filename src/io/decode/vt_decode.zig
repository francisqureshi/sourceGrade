const std = @import("std");
const media = @import("../media.zig");
const vtb = @import("videotoolbox_c.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
pub const log = std.log.scoped(.videoToolBox);

pub fn decode(SourceMedia: media.SourceMedia) void {
    var format_desc: vtb.CMVideoFormatDescriptionRef = null;

    vtb.CMVideoFormatDescriptionCreate(null, @bitCast(SourceMedia.codec), SourceMedia.resolution.width, SourceMedia.resolution.height, null, &format_desc);
}
