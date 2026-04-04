const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const SourceMedia = @import("../io/media/media.zig").SourceMedia;
const Resolution = @import("../units.zig").Resolution;
const Rational = @import("../units.zig").Rational;
const Position = @import("../units.zig").Position;

pub const Track = struct {};

pub const TimelineItem = struct {
    source: *SourceMedia,
    in: u64,
    out: u64,
    position: Position,
};

pub const Timeline = struct {
    name: []const u8,
    db_uuid: ?[16]u8,
    frame_rate: Rational,
    resolution: Resolution,

    start_frame_number: u64, // TC Int
    in_point: u64,
    out_point: u64,

    tracks: []Track,

    pub fn init(allocator: Allocator) Timeline {
        _ = allocator;
    }
};
