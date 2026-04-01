const std = @import("std");

pub const Playback = struct {
    playing: std.atomic.Value(f32),
    speed: std.atomic.Value(f32),
    loop: std.atomic.Value(bool),
    in_point: isize,
    out_point: isize,
    duration_in_frames: i64,

    pub fn init(in_point: isize, out_point: isize, duration_in_frames: i64) Playback {
        return .{
            .playing = std.atomic.Value(f32).init(0.0),
            .speed = std.atomic.Value(f32).init(1.0),
            .loop = std.atomic.Value(bool).init(true),
            .in_point = in_point,
            .out_point = out_point,
            .duration_in_frames = duration_in_frames,
        };
    }
};
