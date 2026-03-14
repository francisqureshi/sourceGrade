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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded = std.Io.Threaded.init(allocator, .{ .environ = init.environ });
    defer threaded.deinit();
    const io = threaded.io();

    // App
    var app = App.init(allocator, io);
    defer app.deinit();

    //Async / conncurrent test
    const timing_rate_ms: i64 = 40;
    var clock_task = try io.concurrent(async_learning.clockA, .{ io, timing_rate_ms });
    defer clock_task.cancel(io);

    // Platform
    var platform = try Platform.init(&app);
    defer platform.deinit();

    try platform.run();
}
