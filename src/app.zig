const std = @import("std");

const renderer = @import("gpu/renderer.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const TestingConfig = struct {
    video_path: []const u8,
};

pub const PlaybackState = struct {
    playing: bool,
    speed: f32,
    current_frame: u64,
};

pub const App = struct {
    allocator: Allocator,
    io: Io,
    config: renderer.RenderConfig,
    test_args: TestingConfig,

    // App owns playback *intent*
    playback_state: ?PlaybackState, // playing, paused, speed, position

    pub fn init(allocator: Allocator, io: Io) App {
        // GPU/rendering config
        const config = renderer.RenderConfig{
            .use_display_p3 = true,
            .use_10bit = true,
        };

        // Test setup args
        const test_args = TestingConfig{
            .video_path = "/Users/fq/Desktop/AGMM/COS_AW25_4K_4444_LR001_LOG_S06.mov",
        };

        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .test_args = test_args,
            .playback_state = null,
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

    pub fn buildUI(self: *App, ui: anytype) void {
        // TODO: will contain imgui widget calls
        _ = self;
        _ = ui;
    }
};
