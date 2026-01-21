const std = @import("std");
const media = @import("media.zig");

const allocator = std.mem.Allocator;

const source_pool = struct {
    sources: std.ArrayHashMapUnmanaged(dbhash, *media.SourceMedia),
};
