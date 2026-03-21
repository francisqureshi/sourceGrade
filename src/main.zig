const std = @import("std");
const builtin = @import("builtin");

const App = @import("app.zig").App;
const Platform = @import("os/mod.zig").Platform;
const Core = @import("core.zig").Core;

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub fn main(init: std.process.Init.Minimal) !void {
    std.debug.print("=== sourceGrade ===\n\n", .{});

    // Main Allocator and Io
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded = std.Io.Threaded.init(allocator, .{ .environ = init.environ });
    defer threaded.deinit();
    const io = threaded.io();

    // Core - Cross Platform Logic
    var core = try Core.init(allocator, io);
    defer core.deinit();

    // App
    var app = try App.init(allocator, io, &core);
    defer app.deinit();

    // Platform specific
    var platform = try Platform.init(&app, &core);
    defer platform.deinit();

    try platform.run();
}
