const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const com = @import("com");
const Core = @import("core.zig").Core;
const Session = @import("playback/session.zig").Session;
const ui = @import("ui/ui.zig");
const Viewer = @import("ui/viewer.zig").Viewer;
const sources_panel = @import("ui/sources_panel.zig");

pub const WindowConfig = union(enum) {
    maximised,
    specific_size: struct { width: u32, height: u32 },
};

pub const App = struct {
    allocator: Allocator,
    io: Io,
    core: *Core,
    viewers: std.ArrayList(Viewer),

    //Test remove soon
    colour_slider: f32,
    test_slider: f32,

    pub fn init(allocator: Allocator, io: Io, core: *Core) !App {
        // Create viewers ArrayList
        var viewers = std.ArrayList(Viewer).empty;

        // Create session for first source (if sources exist)
        var initial_session: ?*Session = null;
        if (core.sources.map.keys().len > 0) {
            const first_uuid = core.sources.map.keys()[0];
            const source = core.sources.get(first_uuid).?;

            const session = try allocator.create(Session);
            session.* = .{ .source = undefined };
            try session.source.init(source, io, allocator);
            try core.sessions.put(allocator, first_uuid, session);
            initial_session = session;
        }

        // Create initial viewer
        const source_viewer = Viewer{
            .x = 50.0,
            .y = 50.0,
            .width = 1000.0,
            .height = 562.0,
            .visible = true,
            .zoom = 1.0,
            .pan_x = 0.0,
            .pan_y = 0.0,
            .session = initial_session,
        };

        try viewers.append(allocator, source_viewer);

        return .{
            .allocator = allocator,
            .io = io,
            .core = core,
            .viewers = viewers,

            .colour_slider = 0.5,
            .test_slider = 0.0,
        };
    }

    pub fn deinit(self: *App) void {
        // Deinit each viewer
        for (self.viewers.items) |*vwr| vwr.deinit();

        self.viewers.deinit(self.allocator);
    }

    pub fn update(self: *App, dt: f32) void {
        _ = self;
        _ = dt;
    }

    pub fn buildUi(self: *App, imgui: *ui.ImGui) !void {
        const transparent = ui.ImGui.packColor(0, 0, 0, 0);

        const project_name = if (self.core.project_manager.current) |proj|
            proj.name
        else
            "-";

        const source_viewer = &self.viewers.items[0];

        // Get session from viewer (early return if no session loaded)
        const session = source_viewer.session orelse return;

        var window_vstack = ui.layout.VStack.init(
            1,
            0,
            imgui.display_width - 1,
            imgui.display_height,
            0,
        ); //INFO: X + 1 px for left edge rendering
        const top_vstack = window_vstack.add(.{ .fill = 1.0 }, .{ .pixels = 28 }, 0);
        const main_vstack = window_vstack.add(.{ .fill = 1.0 }, .{ .fill = 1.0 }, 0);
        window_vstack.solve();

        var top_bar = ui.layout.HStack.init(
            top_vstack.x,
            top_vstack.y,
            top_vstack.w,
            top_vstack.h / 2,
            0,
        );
        const left = top_bar.add(.{ .fill = 0.80 }, .{ .fill = 1.0 }, 0);
        const right = top_bar.add(.{ .fill = 0.20 }, .{ .fill = 1.0 }, 0);
        top_bar.solve();

        try imgui.textLabel(
            left.x,
            left.y,
            left.w,
            left.h,
            project_name,
            transparent,
            .{ 255, 255, 255, 255 },
            .center,
        );
        try imgui.textLabel(
            right.x,
            right.y,
            right.w,
            right.h,
            "*",
            transparent,
            .{ 255, 255, 255, 255 },
            .right,
        );

        var main_upper_hstack = ui.layout.HStack.init(
            main_vstack.x,
            main_vstack.y,
            main_vstack.w,
            main_vstack.h / 2,
            0,
        );
        const sources = main_upper_hstack.add(.{ .fill = 0.33 }, .{ .fill = 1.0 }, 0);
        const viewer_ui = main_upper_hstack.add(.{ .fill = 0.66 }, .{ .fill = 1.0 }, 0);
        main_upper_hstack.solve();

        //:INFO: VIEWER UI
        const current_source = session.getCurrentSource();
        try imgui.viewerControls(
            self.io,
            viewer_ui,
            source_viewer,
            &session.source,
            current_source.duration_in_frames,
        );

        //:INFO: SOURCES UI
        try sources_panel.draw(imgui, sources, self.core, current_source, source_viewer, self.allocator, self.io);
    }
};
