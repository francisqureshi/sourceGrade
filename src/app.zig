const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const com = @import("com");
const Core = @import("core.zig").Core;
const ui = @import("gui/ui.zig");
const VideoMonitor = @import("playback/video_monitor.zig").VideoMonitor;
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

        // Create initial viewer (full-screen for now)
        const source_viewer = Viewer{
            .x = 50.0,
            .y = 50.0,
            .width = 1000.0,
            .height = 562.0,
            .visible = true,
            .zoom = 1.0,
            .pan_x = 0.0,
            .pan_y = 0.0,
            .monitor_id = 0, // References Core.video_monitors[0]
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
        // _ = self;

        // Deinit each viewer
        for (self.viewers.items) |*vwr| vwr.deinit();

        self.viewers.deinit(self.allocator);
    }

    pub fn update(self: *App, dt: f32) void {
        _ = self;
        _ = dt;
    }

    pub fn buildUi(self: *App, imgui: *ui.ImGui) !void {
        // Get video_monitor from Core
        const source_monitor = &self.core.video_monitors.items[0];
        const source_viewer = &self.viewers.items[0];

        var window_vstack = ui.layout.VStack.init(0, 0, imgui.display_width, imgui.display_height, 0);
        window_vstack.add(.{ .fill = 1.0 }, .{ .pixels = 28 }, 0);
        window_vstack.add(.{ .fill = 1.0 }, .{ .fill = 1.0 }, 0);
        window_vstack.solve();

        const top_stack = window_vstack.get(0);
        _ = top_stack;

        const main_stack = window_vstack.get(1);
        var main_hstack = ui.layout.HStack.init(main_stack.x, main_stack.y, main_stack.w, main_stack.h / 2, 0);
        main_hstack.add(.{ .fill = 0.25 }, .{ .fill = 1.0 }, 0);
        main_hstack.add(.{ .fill = 0.25 }, .{ .fill = 1.0 }, 0);
        main_hstack.add(.{ .fill = 0.5 }, .{ .fill = 1.0 }, 0);
        main_hstack.solve();

        const viewer = main_hstack.get(2);

        var viewer_vstack = ui.layout.VStack.init(viewer.x, viewer.y, viewer.w, viewer.h, 0);
        viewer_vstack.add(.{ .fill = 1.0 }, .{ .fill = 1.0 }, 0.0); // viewer
        viewer_vstack.add(.{ .fill = 1.0 }, .{ .pixels = 50.0 }, 0.0); // chin / controls
        viewer_vstack.solve();

        const viewer_video_surface = viewer_vstack.get(0);
        const viewer_chin = viewer_vstack.get(1);

        source_viewer.x = viewer_video_surface.x;
        source_viewer.y = viewer_video_surface.y;
        source_viewer.width = viewer_video_surface.w;
        source_viewer.height = viewer_video_surface.h;

        var viewer_ctrls_vstack = ui.layout.VStack.init(viewer_chin.x, viewer_chin.y, viewer_chin.w, viewer_chin.h, 0);
        viewer_ctrls_vstack.add(.{ .fill = 1.0 }, .{ .pixels = 20.0 }, 0.0); // scrubber
        viewer_ctrls_vstack.add(.{ .fill = 1.0 }, .{ .pixels = 30.0 }, 0.0); // buttons
        viewer_ctrls_vstack.solve();

        const viewer_scrubber = viewer_ctrls_vstack.get(0);
        const viewer_ctrls = viewer_ctrls_vstack.get(1);

        // ============ Video Scrubber
        var scrubber_hstack = ui.layout.HStack.init(viewer_scrubber.x, viewer_scrubber.y, viewer_scrubber.w, viewer_scrubber.h, 0);
        scrubber_hstack.add(.{ .percent = 0.025 }, .{ .fill = 1.0 }, 1.0);
        scrubber_hstack.add(.{ .fill = 1.0 }, .{ .fill = 1.0 }, 1.0);
        scrubber_hstack.add(.{ .percent = 0.025 }, .{ .fill = 1.0 }, 1.0);
        scrubber_hstack.solve();

        const scrubber = scrubber_hstack.get(1);

        var scrubber_slider: usize = source_monitor.current_frame_index.load(.acquire);
        var scrubber_in: usize = @intCast(self.core.playback.in_point);
        var scrubber_out: usize = @intCast(self.core.playback.out_point);
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
            @intCast(self.core.source_media.?.duration_in_frames),
        )) {
            source_monitor.current_frame_index.store(scrubber_slider, .release);

            self.core.playback.in_point = @intCast(scrubber_in);
            self.core.playback.out_point = @intCast(scrubber_out);
        }

        const loop_button_text: []const u8 = if (self.core.playback.loop.load(.acquire)) "loop ON" else "loop OFF";

        // ============ Transport Controls
        var row = ui.layout.HStack.init(viewer_ctrls.x, viewer_ctrls.y, viewer_ctrls.w, viewer_ctrls.h, 10);
        const toolbar_height: ui.layout.SizePolicy = .{ .fill = 1.0 };
        row.add(.{ .pixels = 30 }, toolbar_height, 0.0); // Padd left
        row.add(.{ .pixels = 30 }, toolbar_height, 0.0); // Rev
        row.add(.{ .pixels = 30 }, toolbar_height, 0.0); // Pause
        row.add(.{ .pixels = 30 }, toolbar_height, 0.0); // Fwd
        row.add(.{ .fill = 0.33 }, toolbar_height, 0.0); // Loop
        row.add(.{ .fill = 1.0 }, toolbar_height, 0.0); // TC display
        row.add(.{ .fill = 1.0 }, toolbar_height, 0.0); // Speed slider
        row.solve();

        // const padd_left = row.get(0);
        const rev_rect = row.get(1);
        const pause_rect = row.get(2);
        const fwd_rect = row.get(3);
        const loop_rect = row.get(4);
        const tc_rect = row.get(5);
        const speed_rect = row.get(6);

        const rev_clicked = imgui.iconButton(3, rev_rect.x, rev_rect.y, rev_rect.w, rev_rect.h, .reverse) catch false;
        const pause_clicked = imgui.iconButton(4, pause_rect.x, pause_rect.y, pause_rect.w, pause_rect.h, .pause) catch false;
        const fwd_clicked = imgui.iconButton(5, fwd_rect.x, fwd_rect.y, fwd_rect.w, fwd_rect.h, .play) catch false;
        const loop_clicked = imgui.textButton(6, loop_rect.x, loop_rect.y, loop_rect.w, loop_rect.h, loop_button_text) catch false;

        const current_frame = source_monitor.current_frame_index.load(.acquire);
        var disp_frame_buf: [64]u8 = undefined;
        const frame_text = std.fmt.bufPrint(&disp_frame_buf, "Frame: {d}  Speed: {d:.2}x", .{
            current_frame,
            self.core.playback.speed.load(.acquire),
        }) catch "---";
        try imgui.textLabel(tc_rect.x, tc_rect.y, tc_rect.w, tc_rect.h, frame_text, ui.ImGui.packColor(0.2, 0.2, 0.2, 1), .{ 255, 255, 255, 255 }, .left);

        // ============ Video Controls
        var ctrl_slider: f32 = self.core.playback.speed.load(.acquire);
        if (try imgui.slider(2, speed_rect.x, speed_rect.y, speed_rect.w, speed_rect.h / 2, &ctrl_slider, 0.01, 12.0)) {
            self.core.playback.speed.store(ctrl_slider, .release);
        }

        // Outlines
        try imgui.addRectOutline(viewer_video_surface.x, viewer_video_surface.y, viewer_video_surface.w, viewer_video_surface.h, ui.ImGui.packColor(1, 1, 1, 1), 0.5);
        try imgui.addRectOutline(viewer_chin.x, viewer_chin.y, viewer_chin.w, viewer_chin.h, ui.ImGui.packColor(1, 1, 1, 1), 0.5);

        if (fwd_clicked) {
            self.core.playback.playing.store(1.0, .release);
            try source_monitor.startMonitor(self.io);
        }

        if (rev_clicked) {
            self.core.playback.playing.store(-1.0, .release);
            try source_monitor.startMonitor(self.io);
        }

        if (pause_clicked) {
            self.core.playback.playing.store(0.0, .release);
            source_monitor.stopMonitor(self.io);
        }

        if (loop_clicked) {
            const current = self.core.playback.loop.load(.acquire);
            self.core.playback.loop.store(!current, .release);
        }

        // // V Stack
        // var col = ui.layout.VStack.init(300, 50, 50, 500, 3);
        // const vert_bar_width: ui.layout.SizePolicy = .{ .percent = 0.66 };
        //
        // col.add(vert_bar_width, .{ .percent = 0.33 }, 1.0);
        // for (0..30) |_| {
        //     col.add(vert_bar_width, .{ .fill = 0.10 }, 0.0);
        // }
        // col.solve();
        //
        // imgui.addRect(col.x, col.y, col.w, col.h, ui.ImGui.packColor(0, 0, 0, 1.0)) catch {};
        //
        // for (0..col.child_count) |i| {
        //     const elem = col.get(i);
        //     imgui.addRect(
        //         elem.x,
        //         elem.y,
        //         elem.w,
        //         elem.h,
        //         ui.ImGui.packColor(1, 1, 1, (1 / @as(f32, @floatFromInt(i + 1)))),
        //     ) catch {};
        // }
    }
};
