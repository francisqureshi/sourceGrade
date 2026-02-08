const std = @import("std");
const App = @import("app.zig").App;

const renderer = @import("gpu/renderer.zig"); // TEMP

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub fn main(init: std.process.Init.Minimal) !void {
    std.debug.print("=== sourceGrade ===\n\n", .{});

    // These live for the whole program
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded = std.Io.Threaded.init(allocator, .{ .environ = init.environ });
    defer threaded.deinit();
    const io = threaded.io();

    // App just takes them, doesn't create them
    var app = App.init(allocator, io);
    defer app.deinit();

    var render_result = try renderer.initRenderContext(app.allocator, app.io, app.config);
    defer renderer.deinitRenderContext(app.allocator, &render_result);

    // Spawn render thread
    // FIXME: This maybe should use Io.Threaded.
    const thread = try std.Thread.spawn(.{}, renderer.renderThread, .{&render_result.context});
    thread.detach();

    // Run NSApplication runloop forever (this never returns)
    renderer.runEventLoop();

    // Code below never executes (runloop runs forever)
    unreachable;
}
