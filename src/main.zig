const std = @import("std");
const builtin = @import("builtin");

const App = @import("app.zig").App;
const Platform = @import("os/mod.zig").Platform;

const async_learning = @import("async.zig"); // TEMP Async tests

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

    // App
    var app = try App.init(allocator, io);
    defer app.deinit();

    // Platform
    var platform = try Platform.init(&app);
    defer platform.deinit();

    try platform.run();
}
