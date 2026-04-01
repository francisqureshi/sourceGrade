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

    pub fn createSource(
        self: *Database,
        project_id: i32,
        source_media: *media.SourceMedia,
    ) ![16]u8 {
        return pgdb.createSource(self.pool, project_id, source_media);
    }
};
