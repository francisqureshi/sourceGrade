const std = @import("std");
const pg = @import("pg");

pub const log = std.log.scoped(.reinitDb);

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var io_instance: std.Io.Threaded = .init_single_threaded;
    defer io_instance.deinit();
    const io = io_instance.io();

    log.info("Connecting to database...", .{});

    const pool = pg.Pool.init(allocator, io, .{
        .size = 1,
        .connect = .{
            .port = 5433,
            .host = "127.0.0.1",
        },
        .auth = .{
            .username = "fq",
            // .username = "mac10",
            .database = "sourcegrade",
            .timeout = 10_000,
        },
    }) catch |err| {
        log.err("Failed to connect to database: {}", .{err});
        return err;
    };
    defer pool.deinit();

    log.info("Resetting and reinitializing database schema...", .{});
    try resetAndInitializeDatabase(pool);

    // Create default project
    const project_id = try createProject(pool, "testProject", 24.0);
    log.info("Created default project 'testProject' with id: {d}", .{project_id});

    log.info("Database reinitialized successfully!", .{});
}

fn createProject(pool: *pg.Pool, name: []const u8, frame_rate: f64) !i32 {
    var conn = try pool.acquire();
    defer conn.release();

    const result = try conn.query(
        \\INSERT INTO projects
        \\  (name, default_frame_rate, default_resolution_width, default_resolution_height, working_color_space)
        \\VALUES ($1, $2, $3, $4, $5)
        \\RETURNING id
    , .{ name, frame_rate, 1600, 900, "rec709" });
    defer result.deinit();

    if (try result.next()) |row| {
        return row.get(i32, 0);
    }
    return error.NoProjectCreated;
}

fn resetAndInitializeDatabase(pool: *pg.Pool) !void {
    var conn = try pool.acquire();
    defer conn.release();

    // Drop all dependent tables first
    _ = try conn.exec("DROP TABLE IF EXISTS timeline_clips CASCADE", .{});
    _ = try conn.exec("DROP TABLE IF EXISTS grade_nodes CASCADE", .{});
    _ = try conn.exec("DROP TABLE IF EXISTS timelines CASCADE", .{});
    _ = try conn.exec("DROP TABLE IF EXISTS versions CASCADE", .{});
    _ = try conn.exec("DROP TABLE IF EXISTS sources CASCADE", .{});
    _ = try conn.exec("DROP TABLE IF EXISTS projects CASCADE", .{});

    // Recreate projects table
    _ = try conn.exec(
        \\CREATE TABLE projects (
        \\    id SERIAL PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    created_at TIMESTAMPTZ DEFAULT NOW(),
        \\    modified_at TIMESTAMPTZ DEFAULT NOW(),
        \\    default_frame_rate NUMERIC(10,2),
        \\    default_resolution_width INT,
        \\    default_resolution_height INT,
        \\    working_color_space TEXT DEFAULT 'rec709'
        \\)
    , .{});

    // Recreate sources table
    _ = try conn.exec(
        \\CREATE TABLE sources (
        \\    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        \\    project_id INT REFERENCES projects(id) ON DELETE CASCADE,
        \\
        \\    path TEXT NOT NULL UNIQUE,
        \\    filename TEXT NOT NULL,
        \\    file_modified_at TIMESTAMPTZ,
        \\    file_size_bytes BIGINT,
        \\
        \\    codec TEXT,
        \\
        \\    width INT,
        \\    height INT,
        \\    container_width INT,
        \\    container_height INT,
        \\
        \\    frame_rate_num INT,
        \\    frame_rate_den INT,
        \\    frame_rate_float NUMERIC(10,4),
        \\
        \\    time_base_num INT,
        \\    time_base_den INT,
        \\
        \\    start_timecode TEXT,
        \\    end_timecode TEXT,
        \\    drop_frame BOOLEAN DEFAULT FALSE,
        \\    start_frame_number BIGINT DEFAULT 0,
        \\    end_frame_number BIGINT,
        \\
        \\    duration_frames BIGINT,
        \\
        \\    reel_name TEXT,
        \\    color_space TEXT,
        \\
        \\    created_at TIMESTAMPTZ DEFAULT NOW(),
        \\    modified_at TIMESTAMPTZ DEFAULT NOW()
        \\)
    , .{});

    // Recreate timelines table
    _ = try conn.exec(
        \\CREATE TABLE timelines (
        \\    id SERIAL PRIMARY KEY,
        \\    project_id INT REFERENCES projects(id) ON DELETE CASCADE,
        \\    name TEXT NOT NULL,
        \\    frame_rate NUMERIC(10,2),
        \\    duration_frames INT,
        \\    created_at TIMESTAMPTZ DEFAULT NOW(),
        \\    modified_at TIMESTAMPTZ DEFAULT NOW()
        \\)
    , .{});

    // Recreate timeline_clips table
    _ = try conn.exec(
        \\CREATE TABLE timeline_clips (
        \\    id SERIAL PRIMARY KEY,
        \\    timeline_id INT REFERENCES timelines(id) ON DELETE CASCADE,
        \\    source_id UUID REFERENCES sources(id) ON DELETE RESTRICT,
        \\
        \\    source_in_frame INT NOT NULL,
        \\    source_out_frame INT NOT NULL,
        \\
        \\    timeline_in_frame INT NOT NULL,
        \\    timeline_out_frame INT NOT NULL,
        \\
        \\    track_index INT DEFAULT 0,
        \\    speed_multiplier NUMERIC(10,4) DEFAULT 1.0,
        \\
        \\    enabled BOOLEAN DEFAULT true,
        \\    created_at TIMESTAMPTZ DEFAULT NOW(),
        \\    modified_at TIMESTAMPTZ DEFAULT NOW()
        \\)
    , .{});

    // Recreate grade_nodes table
    _ = try conn.exec(
        \\CREATE TABLE grade_nodes (
        \\    id SERIAL PRIMARY KEY,
        \\    timeline_clip_id INT REFERENCES timeline_clips(id) ON DELETE CASCADE,
        \\
        \\    node_type TEXT NOT NULL,
        \\    node_label TEXT,
        \\    parameters JSONB NOT NULL,
        \\
        \\    position INT NOT NULL,
        \\    enabled BOOLEAN DEFAULT true,
        \\
        \\    created_at TIMESTAMPTZ DEFAULT NOW(),
        \\    modified_at TIMESTAMPTZ DEFAULT NOW()
        \\)
    , .{});

    // Recreate versions table
    _ = try conn.exec(
        \\CREATE TABLE versions (
        \\    id SERIAL PRIMARY KEY,
        \\    project_id INT REFERENCES projects(id) ON DELETE CASCADE,
        \\    created_at TIMESTAMPTZ DEFAULT NOW(),
        \\    description TEXT,
        \\    created_by TEXT,
        \\    snapshot_data JSONB
        \\)
    , .{});

    // Create indexes
    _ = try conn.exec("CREATE INDEX idx_timeline_clips_timeline ON timeline_clips(timeline_id)", .{});
    _ = try conn.exec("CREATE INDEX idx_timeline_clips_source ON timeline_clips(source_id)", .{});
    _ = try conn.exec("CREATE INDEX idx_grade_nodes_clip ON grade_nodes(timeline_clip_id)", .{});
    _ = try conn.exec("CREATE INDEX idx_sources_path ON sources(path)", .{});

    log.info("Schema created", .{});
}
