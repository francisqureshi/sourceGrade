const std = @import("std");
const builtin = @import("builtin");

const pg = @import("pg");
const pgdb = @import("pgdb.zig");
const media = @import("../media.zig");

const Allocator = std.mem.Allocator;
// const Io = std.Io;
pub const log = std.log.scoped(.pgSQL);

pub fn testPgsql() !void {
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
            // .username = "mac10",
            .username = "fq",
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

pub fn addSourceToDB(allocator: Allocator, source_media: media.SourceMedia) !void {
    // Initialize database
    var io_impl = std.Io.Threaded.init(allocator, .{});
    defer io_impl.deinit();
    const db_io = io_impl.io();

    var pool = pg.Pool.init(allocator, .{ .io = db_io, .size = 5, .connect = .{
        .port = 5433,
        .host = "127.0.0.1",
    }, .auth = .{
        .username = "fq",
        .database = "sourcegrade",
        .timeout = 10_000,
    } }) catch |err| {
        log.err("Failed to connect to database: {}", .{err});
        return;
    };
    defer pool.deinit();

    // Initialize database schema
    try pgdb.resetAndInitializeDatabase(pool);

    // Store source in database
    const source_id = try pgdb.createSource(pool, &source_media);
    std.debug.print("✓ Created source ID: {d}\n", .{source_id});

    // Retrieve and verify
    if (try pgdb.getSourceById(pool, source_id)) |retrieved| {
        std.debug.print("\n✓ Retrieved source from database:\n", .{});
        std.debug.print("  ID: {d}\n", .{retrieved.id});
        std.debug.print("  File: {s}\n", .{retrieved.filename});
        std.debug.print("  Codec: {s}\n", .{retrieved.codec});
        std.debug.print("    → Codec bytes: ", .{});
        for (retrieved.codec) |b| std.debug.print("{c}", .{@as(u8, b)});
        std.debug.print("\n", .{});
        std.debug.print("  Resolution: {d}x{d}\n", .{ retrieved.width, retrieved.height });
        std.debug.print("  Container: {?d}x{?d}\n", .{ retrieved.container_width, retrieved.container_height });
        std.debug.print("  Frame rate: {d}/{d} = {d:.2}fps\n", .{ retrieved.frame_rate_num, retrieved.frame_rate_den, @as(f32, @floatFromInt(retrieved.frame_rate_num)) / @as(f32, @floatFromInt(retrieved.frame_rate_den)) });
        std.debug.print("  Duration: {d} frames\n", .{retrieved.duration_frames});
        std.debug.print("  Start TC: {s} -> End TC: {?s}\n", .{ retrieved.start_timecode, retrieved.end_timecode });
        std.debug.print("  Drop frame: {}\n", .{retrieved.drop_frame});
        std.debug.print("  File size: {?d} bytes\n", .{retrieved.file_size_bytes});
    } else {
        std.debug.print("ERROR: Could not retrieve source from database\n", .{});
    }

    // List all sources
    // Initialize database schema
    try pgdb.resetAndInitializeDatabase(pool);
    try pgdb.listSources(pool);
}
