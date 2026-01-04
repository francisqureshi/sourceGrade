//! Implements a texture atlas (https://en.wikipedia.org/wiki/Texture_atlas).
//!
//! The implementation is based on "A Thousand Ways to Pack the Bin - A
//! Practical Approach to Two-Dimensional Rectangle Bin Packing" by Jukka
//! Jylänki. This specific implementation is based heavily on
//! Nicolas P. Rougier's freetype-gl project as well as Jukka's C++
//! implementation: https://github.com/juj/RectangleBinPack
//!
//! Copied from Ghostty (https://github.com/ghostty-org/ghostty)
//! with minimal modifications for sourceGrade.
//!
//! Limitations that are easy to fix, but I didn't need them:
//!
//!   * Written data must be packed, no support for custom strides.
//!   * Texture is always a square, no ability to set width != height. Note
//!     that regions written INTO the atlas do not have to be square, only
//!     the full atlas texture itself.
//!
const Atlas = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const log = std.log.scoped(.atlas);

/// Data is the raw texture data.
data: []u8,

/// Width and height of the atlas texture. The current implementation is
/// always square so this is both the width and the height.
size: u32 = 0,

/// The nodes (rectangles) of available space.
nodes: std.ArrayListUnmanaged(Node) = .{},

/// The format of the texture data being written into the Atlas. This must be
/// uniform for all textures in the Atlas. If you have some textures with
/// different formats, you must use multiple atlases or convert the textures.
format: Format = .grayscale,

/// This will be incremented every time the atlas is modified. This is useful
/// for knowing if the texture data has changed since the last time it was
/// sent to the GPU. It is up the user of the atlas to read this value atomically
/// to observe it.
modified: std.atomic.Value(usize) = .{ .raw = 0 },

/// This will be incremented every time the atlas is resized. This is useful
/// for knowing if a GPU texture can be updated in-place or if it requires
/// a resize operation.
resized: std.atomic.Value(usize) = .{ .raw = 0 },

pub const Format = enum(u8) {
    grayscale = 0,
    rgb = 1,
    rgba = 2,

    pub fn depth(self: Format) u8 {
        return switch (self) {
            .grayscale => 1,
            .rgb => 3,
            .rgba => 4,
        };
    }
};

const Node = struct {
    x: u32,
    y: u32,
    width: u32,
};

pub const Error = error{
    /// Atlas cannot fit the desired region. You must enlarge the atlas.
    AtlasFull,
};

/// A region within the texture atlas. These can be acquired using the
/// "reserve" function. A region reservation is required to write data.
pub const Region = extern struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

pub fn init(alloc: Allocator, size: u32, format: Format) Allocator.Error!Atlas {
    var result = Atlas{
        .data = try alloc.alloc(u8, size * size * format.depth()),
        .size = size,
        .nodes = .{},
        .format = format,
    };
    errdefer result.deinit(alloc);

    try result.nodes.ensureUnusedCapacity(alloc, 64);
    result.clear();

    return result;
}

pub fn deinit(self: *Atlas, alloc: Allocator) void {
    self.nodes.deinit(alloc);
    alloc.free(self.data);
    self.* = undefined;
}

/// Reserve a region within the atlas with the given width and height.
pub fn reserve(
    self: *Atlas,
    alloc: Allocator,
    width: u32,
    height: u32,
) (Allocator.Error || Error)!Region {
    var region: Region = .{ .x = 0, .y = 0, .width = width, .height = height };

    if (width == 0 and height == 0) return region;

    const best_idx: usize = best_idx: {
        var best_height: u32 = std.math.maxInt(u32);
        var best_width: u32 = best_height;
        var chosen: ?usize = null;

        var i: usize = 0;
        while (i < self.nodes.items.len) : (i += 1) {
            const y = self.fit(i, width, height) orelse continue;

            const node = self.nodes.items[i];
            if ((y + height) < best_height or
                ((y + height) == best_height and
                    (node.width > 0 and node.width < best_width)))
            {
                chosen = i;
                best_width = node.width;
                best_height = y + height;
                region.x = node.x;
                region.y = y;
            }
        }

        break :best_idx chosen orelse return Error.AtlasFull;
    };

    try self.nodes.insert(alloc, best_idx, .{
        .x = region.x,
        .y = region.y + height,
        .width = width,
    });

    var i: usize = best_idx + 1;
    while (i < self.nodes.items.len) : (i += 1) {
        const node = &self.nodes.items[i];
        const prev = self.nodes.items[i - 1];
        if (node.x < (prev.x + prev.width)) {
            const shrink = prev.x + prev.width - node.x;
            node.x += shrink;
            node.width -|= shrink;
            if (node.width <= 0) {
                _ = self.nodes.orderedRemove(i);
                i -= 1;
                continue;
            }
        }

        break;
    }
    self.merge();

    return region;
}

fn fit(self: Atlas, idx: usize, width: u32, height: u32) ?u32 {
    const node = self.nodes.items[idx];
    if ((node.x + width) > (self.size - 1)) return null;

    var y = node.y;
    var i = idx;
    var width_left = width;
    while (width_left > 0) : (i += 1) {
        const n = self.nodes.items[i];
        if (n.y > y) y = n.y;

        if ((y + height) > (self.size - 1)) return null;

        width_left -|= n.width;
    }

    return y;
}

fn merge(self: *Atlas) void {
    var i: usize = 0;
    while (i < self.nodes.items.len - 1) {
        const node = &self.nodes.items[i];
        const next = self.nodes.items[i + 1];
        if (node.y == next.y) {
            node.width += next.width;
            _ = self.nodes.orderedRemove(i + 1);
            continue;
        }

        i += 1;
    }
}

pub fn set(self: *Atlas, reg: Region, data: []const u8) void {
    assert(reg.x < (self.size - 1));
    assert((reg.x + reg.width) <= (self.size - 1));
    assert(reg.y < (self.size - 1));
    assert((reg.y + reg.height) <= (self.size - 1));

    const depth = self.format.depth();
    var i: u32 = 0;
    while (i < reg.height) : (i += 1) {
        const tex_offset = (((reg.y + i) * self.size) + reg.x) * depth;
        const data_offset = i * reg.width * depth;
        @memcpy(
            self.data[tex_offset .. tex_offset + (reg.width * depth)],
            data[data_offset .. data_offset + (reg.width * depth)],
        );
    }

    _ = self.modified.fetchAdd(1, .monotonic);
}

pub fn grow(self: *Atlas, alloc: Allocator, size_new: u32) Allocator.Error!void {
    assert(size_new >= self.size);
    if (size_new == self.size) return;

    const data_old = self.data;
    const size_old = self.size;

    self.data = try alloc.alloc(u8, size_new * size_new * self.format.depth());
    defer alloc.free(data_old);
    errdefer {
        alloc.free(self.data);
        self.data = data_old;
    }

    try self.nodes.append(alloc, .{
        .x = size_old - 1,
        .y = 1,
        .width = size_new - size_old,
    });

    self.size = size_new;
    @memset(self.data, 0);
    self.set(.{
        .x = 0,
        .y = 1,
        .width = size_old,
        .height = size_old - 2,
    }, data_old[size_old * self.format.depth() ..]);

    _ = self.modified.fetchAdd(1, .monotonic);
    _ = self.resized.fetchAdd(1, .monotonic);
}

pub fn clear(self: *Atlas) void {
    _ = self.modified.fetchAdd(1, .monotonic);
    @memset(self.data, 0);
    self.nodes.clearRetainingCapacity();
    self.nodes.appendAssumeCapacity(.{ .x = 1, .y = 1, .width = self.size - 2 });
}
