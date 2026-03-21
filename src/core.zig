const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const config = @import("config.zig");

pub const Playback = struct {
    playing: std.atomic.Value(f32),
    speed: std.atomic.Value(f32),
    loop: std.atomic.Value(bool),
    in_point: isize,
    out_point: isize,
};

pub const Core = struct {
    allocator: Allocator,
    io: Io,

    cfg: config.Config,
    playback: Playback,

    pub fn init(allocator: Allocator, io: Io) !Core {

        // Load and parse all configuration
        const cfg = try config.Config.load(io, allocator);

        // Initialize playback state with test in/out points
        const playback_state: Playback = .{
            .playing = std.atomic.Value(f32).init(0.0),
            .speed = std.atomic.Value(f32).init(1.0),
            .loop = std.atomic.Value(bool).init(false),
            .in_point = cfg.testing.in_point,
            .out_point = cfg.testing.out_point,
        };

        return .{
            .allocator = allocator,
            .io = io,
            .cfg = cfg,
            .playback = playback_state,
        };
    }

    pub fn deinit(self: *Core) void {
        self.cfg.deinit(self.allocator);
    }
};
