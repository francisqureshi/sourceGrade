const std = @import("std");

const com = @import("com");

const App = @import("../../app.zig").App;
const ui = @import("../../gui/ui.zig");
const ImGuiRenderer = @import("ui_renderer.zig").ImGuiRenderer;
const rend = @import("renderer.zig");
const wnd = @import("window.zig");

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
    constants: com.common.Constants,

    /// Destroys the renderer, window, and config in reverse creation order.
    pub fn deinit(self: *Platform) void {
        self.imgui_ctx.deinit();
        self.render.cleanup(self.app.allocator) catch return;
        try self.wnd.cleanup();

        self.app.allocator.destroy(self.imgui_ctx);
        self.constants.cleanup(self.app.allocator);

        std.debug.print("bye! from Platform.deinit()\n", .{});
    }

    /// Creates the window, loads config, initialises the renderer, and uploads
    /// the initial scene data returned by `App.vkDemo`.
    pub fn init(app: *App) !Platform {
        const wnd_title = " zvk x sourceGrade";
        const window = try wnd.Wnd.create(wnd_title, app.wnd_config);

        // Initialize ImGui context on heap so pointer stays valid
        const imgui_ctx = try app.allocator.create(ui.ImGui);
        imgui_ctx.* = try ui.ImGui.init(app.allocator);

        const constants = try com.common.Constants.load(app.io, app.allocator);
        var render = try rend.Render.create(app.allocator, app.io, constants, window.window);

        var arena = std.heap.ArenaAllocator.init(app.allocator);
        const arena_alloc = arena.allocator();
        defer arena.deinit();

        const init_data = try App.vkDemo(arena_alloc);
        try render.init(app.allocator, &init_data);

        return .{
            .app = app,
            .wnd = window,
            .imgui_ctx = imgui_ctx,
            .constants = constants,
            .render = render,
        };
    }

    /// Runs the main loop: polls events, calls `App.update`, and renders each
    /// frame until the window is closed.
    pub fn run(self: *Platform) !void {
        var timer = try std.time.Timer.start();
        var last_time = timer.read();
        var update_time = last_time;
        var delta_update: f32 = 0.0;
        const time_u: f32 = 1.0 / self.constants.ups;

        while (!self.wnd.closed) {
            const now = timer.read();
            const delta_ns = now - last_time;
            const delta_sec = @as(f32, @floatFromInt(delta_ns)) / 1_000_000_000.0;
            delta_update += delta_sec / time_u;

            try self.wnd.pollEvents();

            // ============ Build IMGUI frame
            self.imgui_ctx.newFrame();

            self.imgui_ctx.mouse_x = self.wnd.mouse_state.x;
            self.imgui_ctx.mouse_y = self.wnd.mouse_state.y;
            self.imgui_ctx.mouse_down = self.wnd.mouse_state.flags.left;
            self.imgui_ctx.mouse_two_down = self.wnd.mouse_state.flags.right;

            self.app.buildUI(self.imgui_ctx);
            try self.imgui_ctx.endFrame();

            self.app.update(delta_sec);

            if (delta_update >= 1) {
                const dif_update_secs = @as(f32, @floatFromInt(now - update_time)) / 1_000_000_000.0;
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
