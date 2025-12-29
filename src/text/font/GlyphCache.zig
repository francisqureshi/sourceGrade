//! Cache for rendered glyphs with their atlas locations

const GlyphCache = @This();

const std = @import("std");
const Glyph = @import("Glyph.zig");

const Allocator = std.mem.Allocator;

/// Map from glyph ID to cached glyph info
map: std.AutoHashMapUnmanaged(u16, Glyph) = .{},

pub fn init() GlyphCache {
    return .{};
}

pub fn deinit(self: *GlyphCache, allocator: Allocator) void {
    self.map.deinit(allocator);
}

/// Get a cached glyph by ID, or null if not cached
pub fn get(self: *GlyphCache, glyph_id: u16) ?Glyph {
    return self.map.get(glyph_id);
}

/// Store a glyph in the cache
pub fn put(self: *GlyphCache, allocator: Allocator, glyph: Glyph) !void {
    try self.map.put(allocator, glyph.id, glyph);
}

/// Check if a glyph is cached
pub fn contains(self: *GlyphCache, glyph_id: u16) bool {
    return self.map.contains(glyph_id);
}

/// Clear all cached glyphs
pub fn clear(self: *GlyphCache) void {
    self.map.clearRetainingCapacity();
}
