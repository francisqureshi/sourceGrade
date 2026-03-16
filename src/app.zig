const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const com = @import("com");
const renderer = @import("gpu/renderer.zig");
const ui = @import("gui/ui.zig");
const VideoMonitor = @import("gpu/video_monitor.zig").VideoMonitor;

pub const WindowConfig = union(enum) {
    maximised,
    specific_size: struct { width: u32, height: u32 },
};

const TestingConfig = struct {
    video_path: []const u8,
};

pub const Playback = struct {
    playing: std.atomic.Value(f32),
    speed: std.atomic.Value(f32),
    loop: std.atomic.Value(bool),
    current_frame: u64,
    in_point: isize,
    out_point: isize,
};

pub const App = struct {
    allocator: Allocator,
    io: Io,
    rndr_config: renderer.RenderConfig, //FIXME: this is just cfg now, migrate to toml cfg?
    wnd_config: WindowConfig,
    test_args: TestingConfig,

    // App owns playback *intent*
    playback: Playback, // playing, paused, speed, position

    test_slider_value: f32,

    pub fn init(allocator: Allocator, io: Io) App {

        // FIXME: Implement for macos too!! / via toml
        //
        // Window config
        const wnd_config = WindowConfig.maximised;

        // Window config specific
        // const wnd_config: WindowConfig = .{
        // .specific_size = .{
        //     .width = 1600,
        //     .height = 900,
        // },
        // };

        // GPU/rendering config
        const config = renderer.RenderConfig{
            .use_display_p3 = true,
            .use_10bit = true,
        };

        // Test setup args
        const test_args = TestingConfig{
            .video_path = "/Users/fq/Desktop/AGMM/A_0005C014_251204_170032_p1CMW_S01.mov",
            // .video_path = "/Users/mac10/Desktop/A_0005C014_251204_170032_p1CMW_S01.mov",
        };

        //FIXME: cfg

        const in_point = 15;
        const out_point = 45;
        const playback_state: Playback = .{
            .playing = std.atomic.Value(f32).init(0.0),
            .speed = std.atomic.Value(f32).init(1.0),
            .loop = std.atomic.Value(bool).init(false),
            .in_point = in_point,
            .current_frame = 0 + in_point,
            .out_point = out_point,
        };

        return .{
            .allocator = allocator,
            .io = io,
            .wnd_config = wnd_config,
            .rndr_config = config,
            .test_args = test_args,
            .playback = playback_state,
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

    pub fn vkDemo(arena_alloc: std.mem.Allocator) !com.mdata.Init {
        const left_quad_model = com.mdata.Model{
            .id = "LeftQuadModel",
            .meshes = &[_]com.mdata.Mesh{
                .{
                    .id = "LeftQuadMesh",
                    .vertices = &[_]f32{
                        -0.99, // '0' Vertex Triplet
                        0.99,
                        0.0,
                        -0.2, // '1' Vertex
                        0.5,
                        0.0,
                        -0.2, // '2' Vertex
                        -0.5,
                        0.0,
                        -0.8, // '3' Vertex
                        -0.5,
                        0.0,
                    },
                    .indices = &[_]u32{
                        0, // Tri 0
                        1,
                        2,
                        0, // Tri 1
                        2,
                        3,
                    },
                },
            },
        };

        const right_quad_model = com.mdata.Model{
            .id = "RightQuadModel",
            .meshes = &[_]com.mdata.Mesh{
                .{
                    .id = "RightQuadMesh",
                    .vertices = &[_]f32{
                        0.8, // '0' Vertex Triplet
                        0.5,
                        0.0,
                        0.2, // '1' Vertex
                        0.5,
                        0.0,
                        0.2, // '2' Vertex
                        -0.5,
                        0.0,
                        0.8, // '3' Vertex
                        -0.5,
                        0.0,
                    },
                    .indices = &[_]u32{
                        0, // Tri 0
                        1,
                        2,
                        0, // Tri 1
                        2,
                        3,
                    },
                },
            },
        };

        const models = try arena_alloc.alloc(com.mdata.Model, 2);
        models[0] = left_quad_model;
        models[1] = right_quad_model;

        return .{ .models = models };
    }

    pub fn buildUI(self: *App, imgui: *ui.ImGui, video_monitor: *VideoMonitor) !void {

        // Test slider and rects
        _ = try imgui.slider(1, 1400, 300, 100, 50, &self.test_slider_value, 0, 1);
        imgui.addRect(1400, 50, 100, 100, ui.ImGui.packColor(self.test_slider_value, 1, 0, 1.0)) catch {};
        imgui.addRect(1450, 100, 100, 100, ui.ImGui.packColor(0, 0, 1, 1.0)) catch {};

        // ============ Video Controls
        var ctrl_slider: f32 = self.playback.speed.load(.acquire);
        if (try imgui.slider(2, 600, 800, 400, 10, &ctrl_slider, 0.01, 8.0)) {
            self.playback.speed.store(ctrl_slider, .release);
        }

        const fwd_button_text: []const u8 = if (self.playback.playing.load(.acquire) != 0.0) "pause" else "play >";
        const rev_button_text: []const u8 = if (self.playback.playing.load(.acquire) != 0.0) "pause" else "< play";

        const loop_button_text: []const u8 = if (self.playback.loop.load(.acquire)) "loop ON" else "loop OFF";

        const rev_clicked = imgui.button(3, 445, 450, 150, 50, rev_button_text) catch false;
        const fwd_clicked = imgui.button(4, 605, 450, 150, 50, fwd_button_text) catch false;
        const loop_clicked = imgui.button(5, 445 + 75, 550, 150, 50, loop_button_text) catch false;

        if (fwd_clicked) {
            const current = self.playback.playing.load(.acquire);
            const new_state: f32 = if (current == 0.0) 1.0 else 0.0;
            self.playback.playing.store(new_state, .release);

            if (new_state != 0.0) {
                try video_monitor.startMonitor(self.io);
            } else {
                video_monitor.stopMonitor(self.io);
            }
        }

        if (rev_clicked) {
            const current = self.playback.playing.load(.acquire);
            const new_state: f32 = if (current == 0.0) -1.0 else 0.0;
            self.playback.playing.store(new_state, .release);

            if (new_state != 0.0) {
                try video_monitor.startMonitor(self.io);
            } else {
                video_monitor.stopMonitor(self.io);
            }
        }

        if (loop_clicked) {
            const current = self.playback.loop.load(.acquire);
            self.playback.loop.store(!current, .release);
        }

        // Frame counter display
        var disp_frame_buf: [1024]u8 = undefined;
        const disp_frame_num = std.fmt.bufPrint(
            &disp_frame_buf,
            "Frame: {d} Playback Speed: {d:.3}",
            .{ self.playback.current_frame, self.playback.speed.load(.acquire) },
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

        _ = imgui.button(5, btn1_rect.x, btn1_rect.y, btn1_rect.w, btn1_rect.h, "|>") catch false;
        _ = imgui.button(6, scrub_rect.x, scrub_rect.y, scrub_rect.w, scrub_rect.h, "------------|-------") catch false;
        _ = imgui.button(7, tc_rect.x, tc_rect.y, tc_rect.w, tc_rect.h, "TC 00:00:00:00") catch false;
        _ = imgui.button(8, second_fill_rect.x, second_fill_rect.y, second_fill_rect.w, second_fill_rect.h, "Second fill") catch false;

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
