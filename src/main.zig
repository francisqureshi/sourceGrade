const std = @import("std");
const builtin = @import("builtin");
const pg = @import("pg");
const media = @import("io/media.zig");
const pgdb = @import("io/db/pgdb.zig");
// const renderer = @import("gpu/renderer.zig");
const vtbFW = @import("io/decode/videotoolbox_c.zig");

const vtb = @import("io/decode/vtb_decode.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
pub const log = std.log.scoped(.pgSQL);

fn testPgsql() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = if (builtin.mode == .Debug) gpa.allocator() else std.heap.c_allocator;

    // Try to avoid std.Io.Threaded due to EAGAIN bug
    // Initialize std.Io for networking
    var io_impl = std.Io.Threaded.init(allocator, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    // While a connection can be created directly, pools should be used in most
    // cases. The pool's `acquire` method, to get a connection is thread-safe.
    // The pool may start 1 background thread to reconnect disconnected
    // connections (or connections in an invalid state).
    var pool = pg.Pool.init(allocator, .{
        .io = io,
        .size = 5,
        .connect = .{
            .port = 5433,
            .host = "127.0.0.1",
        },
        .auth = .{
            .username = "mac10",
            // .username = "fq",
            .database = "sourcegrade",
            .timeout = 10_000,
        },
    }) catch |err| {
        log.err("Failed to connect: {}", .{err});
        std.process.exit(1);
    };
    defer pool.deinit();

    // Initialize database schema
    try pgdb.resetAndInitializeDatabase(pool);

    // Create a new project
    const project_id = try pgdb.createProject(pool, "testProject", 23.976);
    std.debug.print("Created project ID: {d}\n", .{project_id});

    // List all projects
    try pgdb.listProjects(pool);

    // Retreive project
    const project = try pgdb.getProjectById(pool, project_id);
    std.debug.print("project: {any}\n", .{project});

    // delete project
    try pgdb.deleteProject(pool, project_id);

    // List all projects
    try pgdb.listProjects(pool);
}

fn testSourceIntegration() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize Io
    var threaded: Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    const io = threaded.io();

    // Open a test video file
    // const video_path = "/Users/fq/Desktop/AGMM/COS_AW25_4K_4444_LR001_LOG_S06.mov";
    const video_path = "/Users/mac10/Desktop/A_0005C014_251204_170032_p1CMW_S01.mov";

    const file = Io.Dir.openFileAbsolute(io, video_path, .{}) catch |err| {
        std.debug.print("Could not open test video file: {}\n", .{err});
        return;
    };
    defer file.close(io);

    // Create media context
    const mctx = media.MediaContext{ .file = file, .io = io, .allocator = allocator };

    // Parse media file
    var source_media = try media.SourceMedia.init(mctx);
    defer source_media.deinit(allocator);

    std.debug.print("\n✓ Parsed source media: {s}\n", .{source_media.file_name});
    std.debug.print("  Resolution: {d}x{d}\n", .{ source_media.resolution.width, source_media.resolution.height });
    std.debug.print("  Duration: {d} frames\n", .{source_media.duration_in_frames});
    std.debug.print("  Frame rate: {d}/{d} = {d:.2}fps\n", .{ source_media.frame_rate.num, source_media.frame_rate.den, source_media.frame_rate_float });
    std.debug.print("  StartTC: {s} --- End TC: {s}\n", .{ source_media.start_timecode, source_media.end_timecode });

    // // Initialize database
    // var io_impl = std.Io.Threaded.init(allocator, .{});
    // defer io_impl.deinit();
    // const db_io = io_impl.io();
    //
    // var pool = pg.Pool.init(allocator, .{ .io = db_io, .size = 5, .connect = .{
    //     .port = 5433,
    //     .host = "127.0.0.1",
    // }, .auth = .{
    //     .username = "fq",
    //     .database = "sourcegrade",
    //     .timeout = 10_000,
    // } }) catch |err| {
    //     log.err("Failed to connect to database: {}", .{err});
    //     return;
    // };
    // defer pool.deinit();
    //
    // // Initialize database schema
    // try pgdb.resetAndInitializeDatabase(pool);
    //
    // // Store source in database
    // const source_id = try pgdb.createSource(pool, &source_media);
    // std.debug.print("✓ Created source ID: {d}\n", .{source_id});
    //
    // // Retrieve and verify
    // if (try pgdb.getSourceById(pool, source_id)) |retrieved| {
    //     std.debug.print("\n✓ Retrieved source from database:\n", .{});
    //     std.debug.print("  ID: {d}\n", .{retrieved.id});
    //     std.debug.print("  File: {s}\n", .{retrieved.filename});
    //     std.debug.print("  Codec: {s}\n", .{retrieved.codec});
    //     std.debug.print("    → Codec bytes: ", .{});
    //     for (retrieved.codec) |b| std.debug.print("{c}", .{@as(u8, b)});
    //     std.debug.print("\n", .{});
    //     std.debug.print("  Resolution: {d}x{d}\n", .{ retrieved.width, retrieved.height });
    //     std.debug.print("  Container: {?d}x{?d}\n", .{ retrieved.container_width, retrieved.container_height });
    //     std.debug.print("  Frame rate: {d}/{d} = {d:.2}fps\n", .{ retrieved.frame_rate_num, retrieved.frame_rate_den, @as(f32, @floatFromInt(retrieved.frame_rate_num)) / @as(f32, @floatFromInt(retrieved.frame_rate_den)) });
    //     std.debug.print("  Duration: {d} frames\n", .{retrieved.duration_frames});
    //     std.debug.print("  Start TC: {s} -> End TC: {?s}\n", .{ retrieved.start_timecode, retrieved.end_timecode });
    //     std.debug.print("  Drop frame: {}\n", .{retrieved.drop_frame});
    //     std.debug.print("  File size: {?d} bytes\n", .{retrieved.file_size_bytes});
    // } else {
    //     std.debug.print("ERROR: Could not retrieve source from database\n", .{});
    // }
    //
    // // List all sources
    // // Initialize database schema
    // try pgdb.resetAndInitializeDatabase(pool);
    // try pgdb.listSources(pool);

    // std.debug.print("\nSource integration test passed!\n", .{});

    std.debug.print("\n\n=== VideoToolBox Decoder ===\n\n", .{});
    // VideoToolBox Decode test
    // try vtd.decode(&source_media, &mctx);

    var decoder = try vtb.VideoToolboxDecoder.init(&source_media, &mctx);
    defer decoder.deinit();

    // Decode first frame
    const pixel_buffer = try decoder.decodeFrame(0);
    defer pixel_buffer.deinit();

    std.debug.print("Successfully decoded frame 0: {*}\n", .{pixel_buffer.pixel_buffer});
}

pub fn main() !void {
    std.debug.print("=== sourceGrade ===\n\n", .{});

    // // Setup allocator
    // var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // defer _ = gpa.deinit();
    // const allocator = gpa.allocator();
    //
    // // Initialize GPU/rendering subsystem
    // const config = renderer.RenderConfig{
    //     .use_display_p3 = true,
    //     .use_10bit = true,
    // };
    //
    // var render_result = try renderer.initRenderContext(allocator, config);
    // defer renderer.deinitRenderContext(&render_result);
    //
    // // Spawn render thread
    // const thread = try std.Thread.spawn(.{}, renderer.renderThread, .{&render_result.context});
    // thread.detach();

    // Test PgSQL
    // try testPgsql();
    try testSourceIntegration();

    // // Run NSApplication runloop forever (this never returns)
    // renderer.runEventLoop();
    //
    // // Code below never executes (runloop runs forever)
    // unreachable;
}
