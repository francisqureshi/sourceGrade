const std = @import("std");
const App = @import("../../app.zig").App;

const renderer = @import("../../gpu/renderer.zig");

pub const Platform = struct {
    // Platform state (window, renderer, etc.)
    app: *App,
    render_result: renderer.InitResult,

    pub fn init(app: *App) !Platform {
        // Create window, Metal device, pipelines
        // Setup CVDisplayLink

        var render_result = try renderer.initRenderContext(app.allocator, app.io, app.config);

        // Spawn render thread
        const thread = try std.Thread.spawn(
            .{},
            renderer.renderThread,
            .{&render_result.context},
        );
        thread.detach();
        return .{
            .app = app,
            .render_result = render_result,
        };
    }

    pub fn deinit(self: *Platform) void {
        // Cleanup
        defer renderer.deinitRenderContext(self.app.allocator, &self.render_result);
    }

    pub fn run(self: *Platform) void {
        _ = self;
        // Start CVDisplayLink

        // Run NSApplication event loop (blocks forever)
        renderer.runEventLoop();

        // CVDisplayLink callback calls self.app.update(), self.app.buildUI()

    }
};
