const std = @import("std");
const media = @import("media.zig");

const allocator = std.mem.Allocator;

/// Hashmap of dbUUID paired SourcePoolAllocater Source Medias
pub var source_pool = std.AutoArrayHashMapUnmanaged([16]u8, *media.SourceMedia){};
