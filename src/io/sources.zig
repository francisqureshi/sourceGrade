const std = @import("std");
const media = @import("media.zig");

const allocator = std.mem.Allocator;

pub var source_pool = std.AutoArrayHashMapUnmanaged([16]u8, *media.SourceMedia){};
