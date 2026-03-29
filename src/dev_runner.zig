const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const pg = @import("pg");

const Core = @import("core.zig").Core;
const db_test = @import("io/db/init_db.zig");
const pgdb = @import("io/db/pgdb.zig");
const sources = @import("io/media/sources.zig");

const log = std.log.scoped(.devRunner);

pub fn testHydrate(core: Core) !void {
    const db_pool = try db_test.startDb(core.allocator, core.io);
    defer db_pool.deinit();

    try pgdb.listSources(db_pool);
    try pgdb.hydrateSourceMediaPool(db_pool, core.io, core.allocator);

    //Inspect source_pool
    try inspectSourcePool(core.allocator);
}

fn inspectSourcePool(allocator: Allocator) !void {
    for (sources.source_pool.values()) |source| {
        log.debug("source: {s}", .{source.file_name});
        defer source.deinit();
        allocator.destroy(source);
    }
    defer sources.source_pool.deinit(allocator);
}
