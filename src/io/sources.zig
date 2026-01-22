const std = @import("std");
const media = @import("media.zig");

const allocator = std.mem.Allocator;

const source_pool = struct {
    sources: std.ArrayHashMapUnmanaged([16]u8, *media.SourceMedia),
};
