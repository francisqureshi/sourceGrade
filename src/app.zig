const std = @import("std");

const renderer = @import("gpu/renderer.zig");
const ui = @import("gui/ui.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const TestingConfig = struct {
    video_path: []const u8,
};

pub const PlaybackState = struct {
    playing: f32,
    speed: f32,
    current_frame: u64,
};

pub const App = struct {
    allocator: Allocator,
    io: Io,
    config: renderer.RenderConfig,
    test_args: TestingConfig,

    // App owns playback *intent*
    playback_state: PlaybackState, // playing, paused, speed, position

    test_slider_value: f32,

    pub fn init(allocator: Allocator, io: Io) App {
        // GPU/rendering config
        const config = renderer.RenderConfig{
            .use_display_p3 = true,
            .use_10bit = true,
        };

        // Test setup args
        const test_args = TestingConfig{
            // .video_path = "/Users/fq/Desktop/AGMM/COS_AW25_4K_4444_LR001_LOG_S06.mov",
            .video_path = "/Users/mac10/Desktop/A_0005C014_251204_170032_p1CMW_S01.mov",
        };

        const playback_state: PlaybackState = .{
            .playing = 0.0,
            .speed = 1.0,
            .current_frame = 0,
        };

        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .test_args = test_args,
            .playback_state = playback_state,
            .test_slider_value = 0.5,
        };
    }

    pub fn deinit(self: *App) void {
        // TODO: cleanup
        _ = self;
    }

    pub fn update(self: *App, dt: f32) void {
        // TODO: will contain playback logic
        _ = self;
        _ = dt;
    }

    pub fn buildUI(self: *App, imgui: *ui.ImGuiContext) void {
        // TODO: will contain imgui widget calls

        // Test slider and rects
        imgui.slider(1, 1400, 300, 100, 50, &self.test_slider_value, 0, 1) catch {};
        imgui.addRect(1400, 50, 100, 100, ui.ImGuiContext.packColor(self.test_slider_value, 1, 0, 1.0)) catch {};
        imgui.addRect(1450, 100, 100, 100, ui.ImGuiContext.packColor(0, 0, 1, 1.0)) catch {};

        // ============ Video Controls
        imgui.slider(2, 600, 800, 400, 10, &self.playback_state.speed, 0, 32) catch {};

        const fwd_button_text: []const u8 = if (self.playback_state.playing != 0.0) "pause" else "play >";
        const rev_button_text: []const u8 = if (self.playback_state.playing != 0.0) "pause" else "< play";

        const rev_clicked = imgui.button(3, 445, 450, 150, 50, rev_button_text) catch false;
        const fwd_clicked = imgui.button(4, 605, 450, 150, 50, fwd_button_text) catch false;

        if (fwd_clicked) {
            if (self.playback_state.playing == 0.0) self.playback_state.playing = 1.0 else self.playback_state.playing = 0.0;
        }

        if (rev_clicked) {
            if (self.playback_state.playing == 0.0) self.playback_state.playing = -1.0 else self.playback_state.playing = 0.0;
        }

        // Frame counter display
        var disp_frame_buf: [1024]u8 = undefined;
        const disp_frame_num = std.fmt.bufPrint(
            &disp_frame_buf,
            "Frame: {d} Playback Speed: {d:.2}",
            .{ self.playback_state.current_frame, self.playback_state.speed },
        ) catch "CantGetFrame";
        _ = ui.ImGuiContext.TextWidget.addText(imgui, disp_frame_num, 0, 0, 20.0, .{ 255, 0, 0, 255 }) catch {};

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

        imgui.addRect(row.x, row.y, row.w, row.h, ui.ImGuiContext.packColor(1, 0, 0, 1)) catch {};

        _ = imgui.button(5, btn1_rect.x, btn1_rect.y, btn1_rect.w, btn1_rect.h, "|>") catch false;
        _ = imgui.button(6, scrub_rect.x, scrub_rect.y, scrub_rect.w, scrub_rect.h, "------------|-------") catch false;
        _ = imgui.button(7, tc_rect.x, tc_rect.y, tc_rect.w, tc_rect.h, "TC 00:00:00:00") catch false;
        _ = imgui.button(8, second_fill_rect.x, second_fill_rect.y, second_fill_rect.w, second_fill_rect.h, "Second fill") catch false;

        var col = ui.layout.VStack.init(300, 50, 50, 500, 3);
        const vert_bar_width: ui.layout.SizePolicy = .{ .percent = 0.66 };

        col.add(vert_bar_width, .{ .percent = 0.33 }, 1.0);
        for (0..30) |_| {
            col.add(vert_bar_width, .{ .fill = 0.10 }, 0.0);
        }
        col.solve();

        imgui.addRect(col.x, col.y, col.w, col.h, ui.ImGuiContext.packColor(0, 0, 0, 1.0)) catch {};

        for (0..col.child_count) |i| {
            const elem = col.get(i);
            imgui.addRect(
                elem.x,
                elem.y,
                elem.w,
                elem.h,
                ui.ImGuiContext.packColor(1, 1, 1, (1 / @as(f32, @floatFromInt(i + 1)))),
            ) catch {};
        }
    }
};
