const std = @import("std");
const media = @import("media.zig");

const allocator = std.mem.Allocator;

const source_list = std.ArrayList(media.SourceMedia);

pub fn importSource(sl: source_list, sm: media.SourceMedia) void {
    sl.append(
        allocator,
        sm,
    );
}
