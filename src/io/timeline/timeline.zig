const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const SourceMedia = @import("../../io/media/media.zig").SourceMedia;
const Segment = @import("../conform/segment.zig").Segment;
const Resolution = @import("../units.zig").Resolution;
const Rational = @import("../units.zig").Rational;
const PTRZ = @import("../units.zig").PTRZ;

pub const ItemType = enum {
    source,
    generated,
    effect,
};

pub const TimelineItem = struct {
    name: []const u8,
    item_type: ItemType,
    source: ?*SourceMedia,

    start: u64,
    end: u64,

    source_in: u64,
    source_out: u64,

    position: PTRZ,

    track: usize,

    // segment: *Segment,

    pub fn init(
        source: ?*SourceMedia,
        start: u64,
        end: u64,
        source_in: u64,
        source_out: u64,
        track: usize,
    ) TimelineItem {
        return .{
            .name = source.?.file_name,
            .item_type = ItemType.source,
            .source = source,

            .start = start,
            .end = end,

            .source_in = source_in,
            .source_out = source_out,

            .position = PTRZ.init(),

            .track = track,
        };
    }
};

pub const Timeline = struct {
    allocator: Allocator,
    name: []const u8,
    db_uuid: ?[16]u8,

    frame_rate: Rational,
    resolution: Resolution,

    start_frame_number: u64, // Starting TC Int
    lfoa: u64,
    in_point: ?u64,
    out_point: ?u64,

    tracks: usize,

    items: std.ArrayList(TimelineItem),

    pub fn init(
        allocator: Allocator,
        name: []const u8,
        frame_rate: Rational,
        resolution: Resolution,
        start_frame_number: u64,
    ) Timeline {
        return .{
            .allocator = allocator,
            .name = name,
            .db_uuid = null,
            .frame_rate = frame_rate,
            .resolution = resolution,

            .start_frame_number = start_frame_number,
            .lfoa = start_frame_number,
            .in_point = 0,
            .out_point = null,

            .tracks = 1,

            .items = std.ArrayList(TimelineItem).empty,
        };
    }

    pub fn deinit(self: *Timeline) void {
        self.items.deinit(self.allocator);
    }

    pub fn appendSource(
        self: *Timeline,
        source: *SourceMedia,
        source_in: u64,
        source_out: u64,
        track: usize,
    ) !void {
        const frames = source_out - source_in;
        const tl_clip_in = self.lfoa + @intFromBool(self.lfoa != 0);
        const tl_clip_out = tl_clip_in + frames;
        const tl_item = TimelineItem.init(source, tl_clip_in, tl_clip_out, source_in, source_out, track);

        try self.items.append(self.allocator, tl_item);

        self.lfoa += tl_clip_out;
    }
};
