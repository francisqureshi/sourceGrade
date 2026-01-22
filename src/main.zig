const std = @import("std");
const builtin = @import("builtin");
const media = @import("io/media.zig");

const pg = @import("pg");
const pgdb = @import("io/db/pgdb.zig");
const db_test = @import("io/db/init_db.zig");

const renderer = @import("gpu/renderer.zig");
const vtbFW = @import("io/decode/videotoolbox_c.zig");

const vtb = @import("io/decode/vtb_decode.zig");

const sources = @import("io/sources.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
pub const log = std.log.scoped(.pgSQL);

fn testSourceIO() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize Io
    var threaded: Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    const io = threaded.io();

    // Open video file
    const file_path = "/Users/fq/Desktop/AGMM/COS_AW25_4K_4444_LR001_LOG_S06.mov";
    const path_two = "/Users/fq/Desktop/AGMM/GreyRedHalf.mov";

    // const file_path = "/Users/fq/Desktop/AGMM/ProRes444_with_Alpha.mov";
    // const file_path = "/Users/mac10/Desktop/A_0005C014_251204_170032_p1CMW_S01.mov";
    // const path_two = "/Users/mac10/Desktop/A_0006C002_251202_172939_a1CLB_S002.mov";

    var source_media = try media.SourceMedia.init(file_path, io, allocator);
    defer source_media.deinit();

    var source_media_two = try media.SourceMedia.init(path_two, io, allocator);
    defer source_media_two.deinit();

    std.debug.print("\n✓ Parsed source media: {s}\n", .{source_media.file_name});
    std.debug.print("  Resolution: {d}x{d}\n", .{ source_media.resolution.width, source_media.resolution.height });

    std.debug.print("\n✓ Parsed source media: {s}\n", .{source_media_two.file_name});
    std.debug.print("  Resolution: {d}x{d}\n", .{ source_media_two.resolution.width, source_media_two.resolution.height });

    // Add parsed source to Db..
    const db_pool = try db_test.startDb(allocator, io);
    defer db_pool.deinit();

    try db_test.addSourceToDb(db_pool, &source_media);
    try db_test.addSourceToDb(db_pool, &source_media_two);
}

fn testHydrate() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize Io
    var threaded: Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    const io = threaded.io();

    const db_pool = try db_test.startDb(allocator, io);
    defer db_pool.deinit();

    try pgdb.listSources(db_pool);
    try pgdb.hydrateSourceMediaPool(db_pool, io, allocator);

    //Inspect source_pool
    try inspectSourcePool(allocator);
}

fn inspectSourcePool(allocator: Allocator) !void {
    for (sources.source_pool.values()) |source| {
        std.debug.print("source: {any}\n", .{source});
        defer source.deinit();
        allocator.destroy(source);
    }
    defer sources.source_pool.deinit(allocator);
}

fn app() !void {

    // Setup Main allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize GPU/rendering subsystem
    const config = renderer.RenderConfig{
        .use_display_p3 = true,
        .use_10bit = true,
    };

    var render_result = try renderer.initRenderContext(allocator, config);
    defer renderer.deinitRenderContext(allocator, &render_result);

    // Spawn render thread
    const thread = try std.Thread.spawn(.{}, renderer.renderThread, .{&render_result.context});
    thread.detach();

    // Run NSApplication runloop forever (this never returns)
    renderer.runEventLoop();

    // Code below never executes (runloop runs forever)
    unreachable;
}

pub fn main() !void {
    std.debug.print("=== sourceGrade ===\n\n", .{});

    // Test PgSQL
    // try db_test.testPgsql();

    // Test IO
    // try testSourceIO();

    // Test reading db / hydrate
    try testHydrate();

    // Run Gui / App
    // try app();
}
