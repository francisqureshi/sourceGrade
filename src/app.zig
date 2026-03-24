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

    pub fn init(allocator: Allocator, io: Io, core: *Core) !App {

        // Create viewers ArrayList
        var viewers = std.ArrayList(Viewer).empty;

        // Create initial viewer (full-screen for now)
        const source_viewer = Viewer{
            .x = 0.0,
            .y = 0.0,
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

    pub fn buildUI(self: *App, imgui: *ui.ImGui) !void {
        // Get video_monitor from Core
        const video_monitor = &self.core.video_monitors.items[0]; // WARN: Hard Code [0]

        // Test slider and rects
        _ = try imgui.slider(1, 1400, 300, 100, 50, &self.colour_slider, 0, 1);
        imgui.addRect(1400, 50, 100, 100, ui.ImGui.packColor(self.colour_slider, 1, 0, 1.0)) catch {};
        imgui.addRect(1450, 100, 100, 100, ui.ImGui.packColor(0, 0, 1, 1.0)) catch {};

        // ============ Video Controls
        var ctrl_slider: f32 = self.core.playback.speed.load(.acquire);
        if (try imgui.slider(2, 600, 800, 400, 10, &ctrl_slider, 0.01, 8.0)) {
            self.core.playback.speed.store(ctrl_slider, .release);
        }

        const fwd_button_text: []const u8 = if (self.core.playback.playing.load(.acquire) != 0.0) "pause" else "play >";
        const rev_button_text: []const u8 = if (self.core.playback.playing.load(.acquire) != 0.0) "pause" else "< play";

        const loop_button_text: []const u8 = if (self.core.playback.loop.load(.acquire)) "loop ON" else "loop OFF";

        const rev_clicked = imgui.button(3, 445, 450, 150, 50, rev_button_text) catch false;
        const fwd_clicked = imgui.button(4, 605, 450, 150, 50, fwd_button_text) catch false;
        const loop_clicked = imgui.button(5, 445 + 75, 550, 150, 50, loop_button_text) catch false;

        if (fwd_clicked) {
            const current = self.core.playback.playing.load(.acquire);
            const new_state: f32 = if (current == 0.0) 1.0 else 0.0;
            self.core.playback.playing.store(new_state, .release);

            if (new_state != 0.0) {
                try video_monitor.startMonitor(self.io);
            } else {
                video_monitor.stopMonitor(self.io);
            }
        }

        if (rev_clicked) {
            const current = self.core.playback.playing.load(.acquire);
            const new_state: f32 = if (current == 0.0) -1.0 else 0.0;
            self.core.playback.playing.store(new_state, .release);

            if (new_state != 0.0) {
                try video_monitor.startMonitor(self.io);
            } else {
                video_monitor.stopMonitor(self.io);
            }
        }

        if (loop_clicked) {
            const current = self.core.playback.loop.load(.acquire);
            self.core.playback.loop.store(!current, .release);
        }

        // Frame counter display (read directly from VideoMonitor)
        const current_frame = video_monitor.current_frame_index.load(.acquire);
        var disp_frame_buf: [1024]u8 = undefined;
        const disp_frame_num = std.fmt.bufPrint(
            &disp_frame_buf,
            "Frame: {d} Playback Speed: {d:.3}",
            .{ current_frame, self.core.playback.speed.load(.acquire) },
        ) catch "CantGetFrame";
        _ = ui.ImGui.TextWidget.addText(imgui, disp_frame_num, 0, 0, 20.0, .{ 255, 0, 0, 255 }) catch {};

        // ============ LAYOUT DEMO
        var row = ui.layout.HStack.init(100, 200, 700, 50, 50);
        const toolbar_height: ui.layout.SizePolicy = .{ .percent = 0.75 };
        row.add(.{ .pixels = 200 }, toolbar_height, 0.1);
        row.add(.{ .pixels = 200 }, toolbar_height, 0.25);
        row.add(.{ .pixels = 200 }, toolbar_height, 0.5);
        row.add(.{ .pixels = 200 }, toolbar_height, 1.0);
        row.solve();

        const btn1_rect = row.get(0);
        const scrub_rect = row.get(1);
        const tc_rect = row.get(2);
        const second_fill_rect = row.get(3);

        imgui.addRect(row.x, row.y, row.w, row.h, ui.ImGui.packColor(1, 0, 0, 1)) catch {};

        _ = imgui.button(6, btn1_rect.x, btn1_rect.y, btn1_rect.w, btn1_rect.h, "|>") catch false;
        _ = imgui.button(7, scrub_rect.x, scrub_rect.y, scrub_rect.w, scrub_rect.h, "------------|-------") catch false;
        _ = imgui.button(8, tc_rect.x, tc_rect.y, tc_rect.w, tc_rect.h, "TC 00:00:00:00") catch false;
        _ = imgui.button(9, second_fill_rect.x, second_fill_rect.y, second_fill_rect.w, second_fill_rect.h, "Second fill") catch false;

        imgui.addCircle(900, 450, 100, 120, ui.ImGui.packColor(0, 0, 1, 1)) catch {};

        var col = ui.layout.VStack.init(300, 50, 50, 500, 3);
        const vert_bar_width: ui.layout.SizePolicy = .{ .percent = 0.66 };

        col.add(vert_bar_width, .{ .percent = 0.33 }, 1.0);
        for (0..30) |_| {
            col.add(vert_bar_width, .{ .fill = 0.10 }, 0.0);
        }
        col.solve();

        imgui.addRect(col.x, col.y, col.w, col.h, ui.ImGui.packColor(0, 0, 0, 1.0)) catch {};

        for (0..col.child_count) |i| {
            const elem = col.get(i);
            imgui.addRect(
                elem.x,
                elem.y,
                elem.w,
                elem.h,
                ui.ImGui.packColor(1, 1, 1, (1 / @as(f32, @floatFromInt(i + 1)))),
            ) catch {};
        }
    }
};
