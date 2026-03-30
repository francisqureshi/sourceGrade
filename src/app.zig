const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const com = @import("com");
const Core = @import("core.zig").Core;
const Session = @import("playback/session.zig").Session;
const ui = @import("gui/ui.zig");
const Viewer = @import("gui/viewer.zig").Viewer;

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

        // Get first source and create session (if sources exist)
        var initial_session: ?*Session = null;
        if (core.sources.map.keys().len > 0) {
            const first_uuid = core.sources.map.keys()[0];
            initial_session = try core.getOrCreateSession(first_uuid);
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

        const source_viewer = &self.viewers.items[0];

        // Get session from viewer (early return if no session loaded)
        const session = source_viewer.session orelse return;

        var window_vstack = ui.layout.VStack.init(1, 0, imgui.display_width - 1, imgui.display_height, 0); // X + 1 px
        const top_stack = window_vstack.add(.{ .fill = 1.0 }, .{ .pixels = 28 }, 0);
        const main_stack = window_vstack.add(.{ .fill = 1.0 }, .{ .fill = 1.0 }, 0);
        window_vstack.solve();

        _ = top_stack;

        var main_hstack = ui.layout.HStack.init(main_stack.x, main_stack.y, main_stack.w, main_stack.h / 2, 0);
        const sources = main_hstack.add(.{ .fill = 0.33 }, .{ .fill = 1.0 }, 0);
        const viewer = main_hstack.add(.{ .fill = 0.66 }, .{ .fill = 1.0 }, 0);
        main_hstack.solve();

        //:INFO: VIEWER UI

        var viewer_vstack = ui.layout.VStack.init(viewer.x, viewer.y, viewer.w, viewer.h, 0);
        const viewer_video_surface = viewer_vstack.add(.{ .fill = 1.0 }, .{ .fill = 1.0 }, 0.0); // viewer
        const viewer_chin = viewer_vstack.add(.{ .fill = 1.0 }, .{ .pixels = 50.0 }, 0.0); // chin / controls
        viewer_vstack.solve();

        source_viewer.x = viewer_video_surface.x;
        source_viewer.y = viewer_video_surface.y;
        source_viewer.width = viewer_video_surface.w;
        source_viewer.height = viewer_video_surface.h;

        var viewer_ctrls_vstack = ui.layout.VStack.init(viewer_chin.x, viewer_chin.y, viewer_chin.w, viewer_chin.h, 0);
        const viewer_scrubber = viewer_ctrls_vstack.add(.{ .fill = 1.0 }, .{ .pixels = 20.0 }, 0.0); // scrubber
        const viewer_ctrls = viewer_ctrls_vstack.add(.{ .fill = 1.0 }, .{ .pixels = 30.0 }, 0.0); // buttons
        viewer_ctrls_vstack.solve();

        //  Video Scrubber
        var scrubber_hstack = ui.layout.HStack.init(viewer_scrubber.x, viewer_scrubber.y, viewer_scrubber.w, viewer_scrubber.h, 0);
        _ = scrubber_hstack.add(.{ .percent = 0.025 }, .{ .fill = 1.0 }, 1.0);
        const scrubber = scrubber_hstack.add(.{ .fill = 1.0 }, .{ .fill = 1.0 }, 1.0);
        _ = scrubber_hstack.add(.{ .percent = 0.025 }, .{ .fill = 1.0 }, 1.0);
        scrubber_hstack.solve();

        var scrubber_slider: usize = session.monitor.current_frame_index.load(.acquire);
        var scrubber_in: usize = @intCast(session.playback.in_point);
        var scrubber_out: usize = @intCast(session.playback.out_point);
        if (try imgui.scrubBar(
            111,
            112,
            113,
            scrubber.x,
            scrubber.y,
            scrubber.w,
            scrubber.h,
            &scrubber_slider,
            &scrubber_in,
            &scrubber_out,
            0,
            @intCast(session.source.duration_in_frames),
        )) {
            session.monitor.current_frame_index.store(scrubber_slider, .release);

            session.playback.in_point = @intCast(scrubber_in);
            session.playback.out_point = @intCast(scrubber_out);
        }

        const loop_button_text: []const u8 = if (session.playback.loop.load(.acquire)) "loop ON" else "loop OFF";

        //  Transport Controls
        var row = ui.layout.HStack.init(viewer_ctrls.x, viewer_ctrls.y, viewer_ctrls.w, viewer_ctrls.h, 10);
        const toolbar_height: ui.layout.SizePolicy = .{ .fill = 1.0 };
        _ = row.add(.{ .pixels = 30 }, toolbar_height, 0.0);
        const rev_rect = row.add(.{ .pixels = 30 }, toolbar_height, 0.0);
        const pause_rect = row.add(.{ .pixels = 30 }, toolbar_height, 0.0);
        const fwd_rect = row.add(.{ .pixels = 30 }, toolbar_height, 0.0);
        const loop_rect = row.add(.{ .fill = 0.33 }, toolbar_height, 0.0);
        const tc_rect = row.add(.{ .fill = 1.0 }, toolbar_height, 0.0);
        const speed_rect = row.add(.{ .fill = 1.0 }, toolbar_height, 0.0);
        row.solve();

        const rev_clicked = imgui.iconButton(3, rev_rect.x, rev_rect.y, rev_rect.w, rev_rect.h, .reverse) catch false;
        const pause_clicked = imgui.iconButton(4, pause_rect.x, pause_rect.y, pause_rect.w, pause_rect.h, .pause) catch false;
        const fwd_clicked = imgui.iconButton(5, fwd_rect.x, fwd_rect.y, fwd_rect.w, fwd_rect.h, .play) catch false;
        const loop_clicked = imgui.textButton(6, loop_rect.x, loop_rect.y, loop_rect.w, loop_rect.h, loop_button_text) catch false;

        const current_frame = session.monitor.current_frame_index.load(.acquire);
        var disp_frame_buf: [64]u8 = undefined;
        const frame_text = std.fmt.bufPrint(&disp_frame_buf, "Frame: {d}  Speed: {d:.2}x", .{
            current_frame,
            session.playback.speed.load(.acquire),
        }) catch "---";
        try imgui.textLabel(tc_rect.x, tc_rect.y, tc_rect.w, tc_rect.h, frame_text, ui.ImGui.packColor(0.2, 0.2, 0.2, 1), .{ 255, 255, 255, 255 }, .left);

        //  Video Controls
        var ctrl_slider: f32 = session.playback.speed.load(.acquire);
        if (try imgui.slider(2, speed_rect.x, speed_rect.y, speed_rect.w, speed_rect.h / 2, &ctrl_slider, 0.01, 12.0)) {
            session.playback.speed.store(ctrl_slider, .release);
        }

        // Outlines
        try imgui.addRectOutline(viewer_video_surface.x, viewer_video_surface.y, viewer_video_surface.w, viewer_video_surface.h, ui.ImGui.packColor(1, 1, 1, 1), 0.5);
        try imgui.addRectOutline(viewer_chin.x, viewer_chin.y, viewer_chin.w, viewer_chin.h, ui.ImGui.packColor(1, 1, 1, 1), 0.5);

        if (fwd_clicked) {
            session.playback.playing.store(1.0, .release);
            try session.monitor.startMonitor(self.io);
        }

        if (rev_clicked) {
            session.playback.playing.store(-1.0, .release);
            try session.monitor.startMonitor(self.io);
        }

        if (pause_clicked) {
            session.playback.playing.store(0.0, .release);
            session.monitor.stopMonitor(self.io);
        }

        if (loop_clicked) {
            const current = session.playback.loop.load(.acquire);
            session.playback.loop.store(!current, .release);
        }

        //:INFO: SOURCES UI
        var sources_vstack = ui.layout.VStack.init(sources.x, sources.y, sources.w, sources.h, 0);
        const titlebar = sources_vstack.add(.{ .fill = 1.0 }, .{ .pixels = 20 }, 1.0);
        const sources_pane = sources_vstack.add(.{ .fill = 1.0 }, .{ .fill = 1.0 }, 1.0);
        sources_vstack.solve();

        try imgui.textLabel(titlebar.x, titlebar.y, titlebar.w, titlebar.h, "Sources", transparent, .{ 255, 255, 255, 255 }, .left);

        // List all sources as clickable buttons
        const row_height: f32 = 24.0;
        const source_keys = self.core.sources.map.keys();
        const source_values = self.core.sources.map.values();

        for (source_keys, source_values, 0..) |uuid, sm, i| {
            const y_offset = sources_pane.y + @as(f32, @floatFromInt(i)) * row_height;

            // Highlight if this is the current session's source
            const is_selected = if (session.source == sm) true else false;
            const bg_color = if (is_selected)
                ui.ImGui.packColor(0.3, 0.3, 0.5, 1.0)
            else
                transparent;

            // Use unique ID based on index (offset to avoid collision with other widgets)
            const button_id: u32 = 1000 + @as(u32, @intCast(i));

            // Draw selection background
            if (is_selected) {
                try imgui.addRect(sources_pane.x, y_offset, sources_pane.w, row_height, bg_color);
            }

            if (try imgui.textButton(button_id, sources_pane.x, y_offset, sources_pane.w, row_height, sm.file_name)) {
                // Switch to this source - get or create session
                const new_session = try self.core.getOrCreateSession(uuid);
                source_viewer.session = new_session;
            }
        }

        // Outlines
        try imgui.addRectOutline(sources.x, sources.y, sources.w, sources.h, ui.ImGui.packColor(1, 1, 1, 1), 0.5);
    }
};
