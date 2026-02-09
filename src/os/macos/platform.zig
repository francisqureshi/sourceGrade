const std = @import("std");
const App = @import("../../app.zig").App;

const renderer = @import("../../gpu/renderer.zig");

// C bridge for Swift window
const c = @cImport({
    @cInclude("metal_window.h");
});

pub const Platform = struct {
    // Platform state (window, renderer, etc.)
    app: *App,
    render_result: renderer.InitResult,

    pub fn init(app: *App) !Platform {
        // Create window, Metal device, pipelines, CVDisplayLink
        const render_result = try renderer.initRenderContext(app.allocator, app.io, app.config);

        return .{
            .app = app,
            .render_result = render_result,
        };
    }

    /// Start the CVDisplayLink vsync callback. Must be called after init()
    /// when the Platform struct is in its final memory location.
    pub fn startDisplayLink(self: *Platform) void {
        const displaylink = self.render_result.context.displaylink orelse return;

        const ctx_ptr = &self.render_result.context;

        // Set callback with pointer to our stable RenderContext
        c.metal_displaylink_set_callback(
            displaylink,
            renderer.displayLinkCallback,
            @ptrCast(ctx_ptr),
        );
        // Dispatch to main thread for rendering
        c.metal_displaylink_set_dispatch_to_main(displaylink, true);
        c.metal_displaylink_start(displaylink);

        std.debug.print("✓ Started CVDisplayLink\n", .{});
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
