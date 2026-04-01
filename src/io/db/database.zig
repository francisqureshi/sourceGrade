// Need to sometimes run the psql server via:
// pg_ctl -D /opt/homebrew/var/postgresql@16 -o "-p 5433" -l /opt/homebrew/var/postgresql@16/server.log start

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const builtin = @import("builtin");

const pg = @import("pg");

const com = @import("com");
const media = @import("../media/media.zig");
const pgdb = @import("pgdb.zig");

pub const log = std.log.scoped(.pgSQL);

pub const Database = struct {
    pool: *pg.Pool,
    allocator: Allocator,

    pub fn init(allocator: Allocator, io: Io, cfg: *const com.common.Constants) !Database {
        // While a connection can be created directly, pools should be used in most
        // cases. The pool's `acquire` method, to get a connection is thread-safe.
        // The pool may start 1 background thread to reconnect disconnected
        // connections (or connections in an invalid state).
        const pool = pg.Pool.init(allocator, io, .{
            .size = 5,
            .connect = .{
                .port = cfg.database_port,
                .host = cfg.database_address,
            },
            .auth = .{
                .username = cfg.username,
                .database = cfg.database_name,
                .timeout = 10_000,
            },
        }) catch |err| {
            log.err("Failed to connect to database: {}", .{err});
            return err;
        };

        return .{
            .pool = pool,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Database) void {
        self.pool.deinit();
    }

    pub fn resetSchema(self: *Database) !void {
        try pgdb.resetAndInitializeDatabase(self.pool);
    }

    pub fn listProjects(self: *Database) !void {
        try pgdb.listProjects(self.pool);
    }

    pub fn listSources(self: *Database) !void {
        try pgdb.listSources(self.pool);
    }

    pub fn createProject(self: *Database, name: []const u8, frame_rate: f64) !i32 {
        return pgdb.createProject(self.pool, name, frame_rate);
    }

    pub fn getProjectById(self: *Database, project_id: i32) !?pgdb.Project {
        return pgdb.getProjectById(self.pool, project_id);
    }

    pub fn deleteProject(self: *Database, project_id: i32) !void {
        try pgdb.deleteProject(self.pool, project_id);
    }

    pub fn createSource(self: *Database, project_id: i32, source_media: *media.SourceMedia) ![16]u8 {
        return pgdb.createSource(self.pool, project_id, source_media);
    }

    pub fn getSourceById(self: *Database, source_id: []const u8) !?pgdb.DbSource {
        return pgdb.getSourceById(self.pool, source_id);
    }
};

// pub fn addSourceToDb(pool: *pg.Pool, project_id: i32, source_media: *media.SourceMedia) !void {
//
//     // Store source in database
//     const source_id = try pgdb.createSource(pool, project_id, source_media);
//
//     // Retrieve and verify
//     if (try pgdb.getSourceById(pool, &source_id)) |retrieved| {
//         std.debug.print("\n✓ Retrieved source from database:\n", .{});
//
//         const hex_id = try pg.uuidToHex(retrieved.id);
//
//         std.debug.print("  ID: {s}\n", .{&hex_id});
//         std.debug.print("  File: {s}\n", .{retrieved.filename});
//         std.debug.print("  Codec: {s}\n", .{retrieved.codec});
//         std.debug.print("    → Codec bytes: ", .{});
//         for (retrieved.codec) |b| std.debug.print("{c}", .{@as(u8, b)});
//         std.debug.print("\n", .{});
//         std.debug.print("  Resolution: {d}x{d}\n", .{ retrieved.width, retrieved.height });
//         std.debug.print("  Container: {?d}x{?d}\n", .{ retrieved.container_width, retrieved.container_height });
//         std.debug.print("  Frame rate: {d}/{d} = {d:.2}fps\n", .{ retrieved.frame_rate_num, retrieved.frame_rate_den, @as(f32, @floatFromInt(retrieved.frame_rate_num)) / @as(f32, @floatFromInt(retrieved.frame_rate_den)) });
//         std.debug.print("  Duration: {d} frames\n", .{retrieved.duration_frames});
//         std.debug.print("  Start TC: {s} -> End TC: {?s}\n", .{ retrieved.start_timecode, retrieved.end_timecode });
//         std.debug.print("  Drop frame: {}\n", .{retrieved.drop_frame});
//         std.debug.print("  File size: {?d} bytes\n", .{retrieved.file_size_bytes});
//     } else {
//         std.debug.print("ERROR: Could not retrieve source from database\n", .{});
//     }
//
//     // List all sources
//     try pgdb.listSources(pool);
// }
//
// pub fn testPgsql(pool: *pg.Pool) !void {
//
//     // Initialize database schema
//     try pgdb.resetAndInitializeDatabase(pool);
//
//     // Create a new project
//     const project_id = try pgdb.createProject(pool, "testProject", 23.976);
//     std.debug.print("Created project ID: {d}\n", .{project_id});
//
//     // List all projects
//     try pgdb.listProjects(pool);
//
//     // Retreive project
//     const project = try pgdb.getProjectById(pool, project_id);
//     std.debug.print("project: {any}\n", .{project});
//
//     // delete project
//     try pgdb.deleteProject(pool, project_id);
//
//     // List all projects
//     try pgdb.listProjects(pool);
// }
