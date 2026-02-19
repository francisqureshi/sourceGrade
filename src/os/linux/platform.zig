const std = @import("std");

const App = @import("../../app.zig").App;

// ============================================================================
// Platform - Linux and Vulkan
// ============================================================================

/// Linux platform layer that orchestrates window, renderer, and display
/// This is the top-level coordinator for the Linux backend.
pub const Platform = struct {
    app: *App,
    pub fn init(app: *App) !Platform {
        std.debug.print("Linux not yet implement", .{});

        return .{
            .app = app,
        };
    }

    pub fn startDisplayLink(self: *Platform) void {
        _ = self;
        std.debug.print("Linux not yet implement", .{});
    }

    pub fn run(self: *Platform) void {
        _ = self;
        std.debug.print("Linux not yet implement", .{});
    }

    pub fn deinit(self: *Platform) void {
        _ = self;
        std.debug.print("Linux not yet implement", .{});
        std.debug.print("bye!", .{});
    }
};
