const std = @import("std");
const builtin = @import("builtin");

const pg = @import("pg");

pub const log = std.log.scoped(.pgSQL);

const Project = struct {
    id: i32,
    name: []const u8,
    frame_rate: ?f64, // Can be null
    created_at: i64, // PostgreSQL timestamp as Unix microseconds
};

pub fn createProject(pool: *pg.Pool, name: []const u8, frame_rate: f64) !i32 {
    var conn = try pool.acquire();
    defer conn.release();

    const result = try conn.query(
        \\INSERT INTO projects 
        \\  (name, default_frame_rate, default_resolution_width, default_resolution_height, working_color_space)
        \\VALUES ($1, $2, $3, $4, $5)
        \\RETURNING id
    , .{ name, frame_rate, 1920, 1080, "rec709" });
    defer result.deinit();

    if (try result.next()) |row| {
        return row.get(i32, 0);
    }
    return error.NoProjectCreated;
}

pub fn listProjects(pool: *pg.Pool) !void {
    var conn = try pool.acquire();
    defer conn.release();

    var result = try conn.queryOpts(
        \\SELECT id, name, default_frame_rate as frame_rate, created_at
        \\FROM projects
        \\ORDER BY created_at DESC
    , .{}, .{ .column_names = true });
    defer result.deinit();

    std.debug.print("\n=== Projects ===\n", .{});

    var mapper = result.mapper(Project, .{ .dupe = true });
    while (try mapper.next()) |project| {
        std.debug.print("ID: {d} | Name: {s} | FPS: {?d}\n", .{
            project.id,
            project.name,
            project.frame_rate,
        });
    }
}

pub fn deleteProject(pool: *pg.Pool, project_id: i32) !void {
    var conn = try pool.acquire();
    defer conn.release();

    const rows = try conn.exec("DELETE FROM projects WHERE id = $1", .{project_id});

    std.debug.print("Deleted project {d} (affected {d} rows)\n", .{ project_id, rows });
}

pub fn resetDatabase(pool: *pg.Pool) !void {
    var conn = try pool.acquire();
    defer conn.release();

    // Delete all projects (cascades to timelines, clips, nodes, versions)
    _ = try conn.exec("DELETE FROM projects", .{});

    // Optionally delete orphaned sources too
    _ = try conn.exec("DELETE FROM sources", .{});

    std.debug.print("Database reset complete\n", .{});
}

pub fn main() !void {
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
    var pool = pg.Pool.init(allocator, .{ .io = io, .size = 5, .connect = .{
        .port = 5433,
        .host = "127.0.0.1",
    }, .auth = .{
        .username = "postgres",
        .database = "sourcegrade",
        .timeout = 10_000,
    } }) catch |err| {
        log.err("Failed to connect: {}", .{err});
        std.process.exit(1);
    };
    defer pool.deinit();

    // One-off commands can be executed directly using the pool using the
    // exec, execOpts, query, queryOpts, row, rowOpts functions. But, due to
    // Zig's lack of error payloads, if these fail, you won't be able to retrieve
    // a more detailed error
    const dropped = try pool.exec("drop table if exists projects", .{});
    std.debug.print("dropped: {any}\n", .{dropped});
}
