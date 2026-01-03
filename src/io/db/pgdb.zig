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

pub fn getProjectById(pool: *pg.Pool, project_id: i32) !?Project {
    var conn = try pool.acquire();
    defer conn.release();

    // row() is perfect for single row lookups
    var row = (try conn.rowOpts(
        \\SELECT id, name, default_frame_rate as frame_rate, created_at
        \\FROM projects
        \\WHERE id = $1
    , .{project_id}, .{ .column_names = true })) orelse return null;
    defer row.deinit() catch {};

    // Manually extract or use .to() for struct mapping
    return Project{
        .id = row.getCol(i32, "id"),
        .name = row.getCol([]const u8, "name"),
        .frame_rate = row.getCol(?f64, "frame_rate"),
        .created_at = row.getCol(i64, "created_at"),
    };
}

pub fn deleteProject(pool: *pg.Pool, project_id: i32) !void {
    var conn = try pool.acquire();
    defer conn.release();

    const rows = try conn.exec("DELETE FROM projects WHERE id = $1", .{project_id});

    std.debug.print("Deleted project {d} (affected {?d} rows)\n", .{ project_id, rows });
}

pub fn resetDatabase(pool: *pg.Pool) !void {
    var conn = try pool.acquire();
    defer conn.release();

    // Delete all projects (cascades to timelines, clips, nodes, versions)
    _ = try conn.exec("DELETE FROM projects", .{});

    // Optionally delete orphaned sources too
    _ = try conn.exec("DELETE FROM projects", .{});

    std.debug.print("Database reset complete\n", .{});
}
