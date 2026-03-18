const std = @import("std");

const com = @import("com");

const App = @import("../../app.zig").App;
const ui = @import("../../gui/ui.zig");
const ImGuiRenderer = @import("ui_renderer.zig").ImGuiRenderer;
const rend = @import("renderer.zig");
const wnd = @import("window.zig");
const VideoMonitor = @import("../../gpu/video_monitor.zig").VideoMonitor;
const Rational = @import("../../io/media.zig").Rational;

// ============================================================================
// Platform - Linux and Vulkan
// ============================================================================

/// Linux platform layer that orchestrates window, renderer, and display
/// This is the top-level coordinator for the Linux backend.
pub const Platform = struct {
    app: *App,
    wnd: wnd.Wnd,
    /// IMGUI context for immediate-mode UI rendering (heap-allocated).
    imgui_ctx: *ui.ImGui,
    render: rend.Render,
    video_monitor: VideoMonitor,
    dummy_frame_rate: Rational, // Dummy for Linux (no video yet)

    /// Destroys the renderer, window in reverse creation order.
    pub fn deinit(self: *Platform) void {
        self.video_monitor.deinit();
        self.imgui_ctx.deinit();
        self.render.cleanup(self.app.allocator) catch return;
        try self.wnd.cleanup();

        self.app.allocator.destroy(self.imgui_ctx);

        std.debug.print("bye! from Platform.deinit()\n", .{});
    }

    /// Creates the window, initialises the renderer, and uploads
    /// the initial scene data returned by `App.vkDemo`.
    pub fn init(app: *App) !Platform {
        const wnd_title = " zvk x sourceGrade";
        const window = try wnd.Wnd.create(wnd_title, app.cfg.window);

        // Initialize ImGui context on heap so pointer stays valid
        const imgui_ctx = try app.allocator.create(ui.ImGui);
        imgui_ctx.* = try ui.ImGui.init(app.allocator);

        var render = try rend.Render.create(app.allocator, app.io, app.cfg.constants, window.window);

        var arena = std.heap.ArenaAllocator.init(app.allocator);
        const arena_alloc = arena.allocator();
        defer arena.deinit();

        const init_data = try App.vkDemo(arena_alloc);
        try render.init(app.allocator, &init_data);

        // Create platform with dummy frame rate (Linux has no video yet)
        var platform = Platform{
            .app = app,
            .wnd = window,
            .imgui_ctx = imgui_ctx,
            .render = render,
            .video_monitor = undefined, // Set below
            .dummy_frame_rate = .{ .num = 24, .den = 1 }, // 24fps placeholder
        };

        // Initialize video monitor with stable frame_rate pointer
        platform.video_monitor = try VideoMonitor.init(
            &platform.dummy_frame_rate,
            app.io,
            app.allocator,
            &app.playback,
        );

        return platform;
    }

    /// Runs the main loop: polls events, calls `App.update`, and renders each
    /// frame until the window is closed.
    pub fn run(self: *Platform) !void {
        var last_time = std.Io.Clock.boot.now(self.app.io);
        var update_time = last_time;
        var delta_update: f32 = 0.0;
        const time_u: f32 = 1.0 / self.app.cfg.constants.ups;

        while (!self.wnd.closed) {
            const now = std.Io.Clock.boot.now(self.app.io);
            const delta_ns = std.Io.Timestamp.durationTo(last_time, now);
            const delta_sec = @as(f32, @floatFromInt(delta_ns.nanoseconds)) / 1_000_000_000.0;
            delta_update += delta_sec / time_u;

            try self.wnd.pollEvents();

            // ============ Build IMGUI frame
            self.imgui_ctx.newFrame();

            self.imgui_ctx.mouse_x = self.wnd.mouse_state.x;
            self.imgui_ctx.mouse_y = self.wnd.mouse_state.y;
            self.imgui_ctx.mouse_down = self.wnd.mouse_state.flags.left;
            self.imgui_ctx.mouse_two_down = self.wnd.mouse_state.flags.right;

            try self.app.buildUI(self.imgui_ctx, &self.video_monitor);
            try self.imgui_ctx.endFrame();

            self.app.update(delta_sec);

            if (delta_update >= 1) {
                const dif_update_secs = @as(f32, @floatFromInt(update_time.durationTo(now).nanoseconds)) / 1_000_000_000.0;
                self.app.update(dif_update_secs);
                delta_update -= 1;
                update_time = now;
            }

            try self.render.render(&self.wnd, self.imgui_ctx);
            errdefer self.deinit();
            last_time = now;
        }
    }
};
