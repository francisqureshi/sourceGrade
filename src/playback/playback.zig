const std = @import("std");

pub const Playback = struct {
    playing: std.atomic.Value(f32),
    speed: std.atomic.Value(f32),
    loop: std.atomic.Value(bool),
    in_point: isize,
    out_point: isize,
};
