const Platform = @import("platform.zig").Platform;
const std = @import("std");

pub const Render = struct {
    pub fn cleanup(self: *Render, allocator: std.mem.Allocator) !void {
        _ = self;
        _ = allocator;
    }

    pub fn create() !Render {
        return .{};
    }

    pub fn render(self: *Render, platform: *Platform) !void {
        _ = self;
        _ = platform;
    }
};
