const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const pg = @import("pg");

const Core = @import("core.zig").Core;
const db_test = @import("io/db/database.zig");
const pgdb = @import("io/db/pgdb.zig");
const sources = @import("io/media/sources.zig");
const Timeline = @import("io/timeline/timeline.zig").Timeline;

const log = std.log.scoped(.devRunner);

pub fn testTimeline(core: *Core) !void {
    const key: [16]u8 = .{ 0xf4, 0x7a, 0xc1, 0x0b, 0x58, 0xcc, 0x43, 0x72, 0xa5, 0x67, 0x0e, 0x02, 0xb2, 0xc3, 0xd4, 0x79 };

    const timeline = try core.allocator.create(Timeline);
    timeline.* = Timeline.init(
        core.allocator,
        "testTimeline1",
        .{ .den = 1, .num = 25 },
        .{ .width = 1920, .height = 1080 },
        1000,
    );

    try timeline.appendSource(core.sources.map.values()[0], 50, 90, 1);
    try timeline.appendSource(core.sources.map.values()[1], 50, 90, 1);

    try core.timelines.put(core.allocator, key, timeline);

    log.debug("TL inspection from map:\n {any}", .{core.timelines.values()[0]});
    log.debug("TL items:", .{});
    for (core.timelines.values()[0].items.items) |i| {
        log.debug("|- {s} | {d} to {d}", .{ i.name, i.start, i.end });
    }

    log.debug("LFOA: {d}", .{core.timelines.values()[0].lfoa});
}

pub fn testHydrate(core: Core) !void {
    const db_pool = try db_test.startDb(core.allocator, core.io);
    defer db_pool.deinit();

    try pgdb.listSources(db_pool);
    try pgdb.hydrateSourceMediaPool(db_pool, core.io, core.allocator);

    //Inspect source_pool
    try inspectSourcePool(core.allocator);

    try pgdb.listProjects(db_pool);
}

fn inspectSourcePool(allocator: Allocator) !void {
    for (sources.source_pool.values()) |source| {
        log.debug("source: {s}", .{source.file_name});
        defer source.deinit();
        allocator.destroy(source);
    }
    defer sources.source_pool.deinit(allocator);
}
