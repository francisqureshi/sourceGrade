const std = @import("std");

const com = @import("com");

const App = @import("../../app.zig").App;
const eng = @import("mod.zig");
const rend = @import("renderer.zig");
const wnd = @import("window.zig");

// ============================================================================
// Platform - Linux and Vulkan
// ============================================================================

pub const InitData = struct {
    models: []const eng.mdata.ModelData,
};

/// Linux platform layer that orchestrates window, renderer, and display
/// This is the top-level coordinator for the Linux backend.
pub const Platform = struct {
    app: *App,
    wnd: wnd.Wnd,
    render: rend.Render,
    constants: com.common.Constants,

    pub fn deinit(self: *Platform) void {
        self.render.cleanup(self.app.allocator) catch return;
        try self.wnd.cleanup();
        self.constants.cleanup(self.app.allocator);

        std.debug.print("bye! from Platform.deinit()\n", .{});
    }

    pub fn init(app: *App) !Platform {
        const wnd_title = " zvk x sourceGrade";
        const window = try wnd.Wnd.create(wnd_title);
        const constants = try com.common.Constants.load(app.io, app.allocator);
        var render = try rend.Render.create(app.allocator, app.io, constants, window.window);

        var arena = std.heap.ArenaAllocator.init(app.allocator);
        const arenaAlloc = arena.allocator();
        defer arena.deinit();

        const initData = try App.vkDemo(arenaAlloc);
        try render.init(app.allocator, &initData);

        return .{
            .app = app,
            .wnd = window,
            .constants = constants,
            .render = render,
        };
    }

    pub fn run(self: *Platform) !void {
        var timer = try std.time.Timer.start();
        var lastTime = timer.read();
        var updateTime = lastTime;
        var deltaUpdate: f32 = 0.0;
        const timeU: f32 = 1.0 / self.constants.ups;

        while (!self.wnd.closed) {
            const now = timer.read();
            const deltaNs = now - lastTime;
            const deltaSec = @as(f32, @floatFromInt(deltaNs)) / 1_000_000_000.0;
            deltaUpdate += deltaSec / timeU;
            try self.wnd.pollEvents();

            self.app.update(deltaSec);

            if (deltaUpdate >= 1) {
                const difUpdateSecs = @as(f32, @floatFromInt(now - updateTime)) / 1_000_000_000.0;
                self.app.update(difUpdateSecs);
                deltaUpdate -= 1;
                updateTime = now;
            }

            try self.render.render(self);
            errdefer self.deinit();
            lastTime = now;
        }
    }
};
