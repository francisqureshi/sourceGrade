const std = @import("std");
const builtin = @import("builtin");

const pg = @import("pg");
const media = @import("../media.zig");

pub const log = std.log.scoped(.pgSQL);

const Project = struct {
    id: i32,
    name: []const u8,
    frame_rate: ?f64, // Can be null
    created_at: i64, // PostgreSQL timestamp as Unix microseconds
};

// Source struct mirrors the sources table schema
pub const Source = struct {
    id: i32,
    path: []const u8,
    filename: []const u8,
    file_modified_at: ?i64,
    file_size_bytes: ?i64,

    codec: []const u8,

    width: i32,
    height: i32,
    container_width: ?i32,
    container_height: ?i32,

    frame_rate_num: i32,
    frame_rate_den: i32,
    frame_rate_float: ?f64,

    time_base_num: ?i32,
    time_base_den: ?i32,

    start_timecode: []const u8,
    end_timecode: ?[]const u8,
    drop_frame: bool,
    start_frame_number: i64,
    end_frame_number: ?i64,

    duration_frames: i64,

    reel_name: ?[]const u8,
    color_space: ?[]const u8,

    created_at: i64,
    modified_at: i64,
};

pub fn createProject(pool: *pg.Pool, name: []const u8, frame_rate: f64) !i32 {
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
    _ = try conn.exec("DELETE FROM sources", .{});

    std.debug.print("Database reset complete\n", .{});
}

// ============================================================================
// Source Media Database Functions
// ============================================================================

pub fn createSource(pool: *pg.Pool, source_media: *const media.SourceMedia) !i32 {
    var conn = try pool.acquire();
    defer conn.release();

    std.debug.print("\n=== Attempting to create source ===\n", .{});
    std.debug.print("Path: {s}\n", .{source_media.file_path});
    std.debug.print("File: {s}\n", .{source_media.file_name});
    std.debug.print("Codec: {s}\n", .{source_media.codec});
    std.debug.print("Resolution: {d}x{d}\n", .{ source_media.resolution.width, source_media.resolution.height });
    std.debug.print("Frame rate: {d}/{d}\n", .{ source_media.frame_rate.num, source_media.frame_rate.den });

    // Simplified INSERT - omit optional/complex fields for now
    const result = try conn.query(
        \\INSERT INTO sources
        \\  (path, filename, codec, width, height,
        \\   frame_rate_num, frame_rate_den,
        \\   start_timecode, end_timecode, drop_frame, duration_frames)
        \\VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
        \\RETURNING id
    , .{
        source_media.file_path,
        source_media.file_name,
        source_media.codec,
        @as(i32, @intCast(source_media.resolution.width)),
        @as(i32, @intCast(source_media.resolution.height)),
        @as(i32, @intCast(source_media.frame_rate.num)),
        @as(i32, @intCast(source_media.frame_rate.den)),
        source_media.start_timecode,
        source_media.end_timecode,
        source_media.drop_frame,
        source_media.duration_in_frames,
    });
    defer result.deinit();

    if (try result.next()) |row| {
        const id = row.get(i32, 0);
        std.debug.print("✓ Created source ID: {d}\n", .{id});
        return id;
    }
    return error.NoSourceCreated;
}

pub fn getSourceById(pool: *pg.Pool, source_id: i32) !?Source {
    var conn = try pool.acquire();
    defer conn.release();

    var row = (try conn.rowOpts(
        \\SELECT id, path, filename, file_modified_at, file_size_bytes,
        \\       codec, width, height, container_width, container_height,
        \\       frame_rate_num, frame_rate_den, frame_rate_float,
        \\       time_base_num, time_base_den,
        \\       start_timecode, end_timecode, drop_frame,
        \\       start_frame_number, end_frame_number,
        \\       duration_frames, reel_name, color_space,
        \\       created_at, modified_at
        \\FROM sources
        \\WHERE id = $1
    , .{source_id}, .{ .column_names = true })) orelse return null;
    defer row.deinit() catch {};

    return Source{
        .id = row.getCol(i32, "id"),
        .path = row.getCol([]const u8, "path"),
        .filename = row.getCol([]const u8, "filename"),
        .file_modified_at = row.getCol(?i64, "file_modified_at"),
        .file_size_bytes = row.getCol(?i64, "file_size_bytes"),
        .codec = row.getCol([]const u8, "codec"),
        .width = row.getCol(i32, "width"),
        .height = row.getCol(i32, "height"),
        .container_width = row.getCol(?i32, "container_width"),
        .container_height = row.getCol(?i32, "container_height"),
        .frame_rate_num = row.getCol(i32, "frame_rate_num"),
        .frame_rate_den = row.getCol(i32, "frame_rate_den"),
        .frame_rate_float = row.getCol(?f64, "frame_rate_float"),
        .time_base_num = row.getCol(?i32, "time_base_num"),
        .time_base_den = row.getCol(?i32, "time_base_den"),
        .start_timecode = row.getCol([]const u8, "start_timecode"),
        .end_timecode = row.getCol(?[]const u8, "end_timecode"),
        .drop_frame = row.getCol(bool, "drop_frame"),
        .start_frame_number = row.getCol(i64, "start_frame_number"),
        .end_frame_number = row.getCol(?i64, "end_frame_number"),
        .duration_frames = row.getCol(i64, "duration_frames"),
        .reel_name = row.getCol(?[]const u8, "reel_name"),
        .color_space = row.getCol(?[]const u8, "color_space"),
        .created_at = row.getCol(i64, "created_at"),
        .modified_at = row.getCol(i64, "modified_at"),
    };
}

pub fn listSources(pool: *pg.Pool) !void {
    var conn = try pool.acquire();
    defer conn.release();

    var result = try conn.queryOpts(
        \\SELECT id, filename, width, height, duration_frames,
        \\       frame_rate_num, frame_rate_den, codec
        \\FROM sources
        \\ORDER BY created_at DESC
    , .{}, .{ .column_names = true });
    defer result.deinit();

    std.debug.print("\n=== Sources ===\n", .{});

    var mapper = result.mapper(struct {
        id: i32,
        filename: []const u8,
        width: i32,
        height: i32,
        duration_frames: i64,
        frame_rate_num: i32,
        frame_rate_den: i32,
        codec: []const u8,
    }, .{ .dupe = true });

    while (try mapper.next()) |source| {
        const fps = @as(f32, @floatFromInt(source.frame_rate_num)) / @as(f32, @floatFromInt(source.frame_rate_den));
        std.debug.print(
            "ID: {d} | {s} | {d}x{d} | {d} frames @ {d:.2}fps | {s}\n",
            .{ source.id, source.filename, source.width, source.height, source.duration_frames, fps, source.codec },
        );
    }
}

pub fn initializeDatabase(pool: *pg.Pool) !void {
    var conn = try pool.acquire();
    defer conn.release();

    // Drop existing dependent tables if they exist (for development/testing)
    _ = try conn.exec("DROP TABLE IF EXISTS timeline_clips, grade_nodes, timelines, sources CASCADE", .{});

    // Recreate sources table with full schema
    _ = try conn.exec(
        \\CREATE TABLE sources (
        \\    id SERIAL PRIMARY KEY,
        \\    
        \\    -- File metadata
        \\    path TEXT NOT NULL UNIQUE,
        \\    filename TEXT NOT NULL,
        \\    file_modified_at TIMESTAMPTZ,
        \\    file_size_bytes BIGINT,
        \\    
        \\    -- Video codec and format
        \\    codec TEXT,
        \\    
        \\    -- Resolution (display)
        \\    width INT,
        \\    height INT,
        \\    container_width INT,
        \\    container_height INT,
        \\    
        \\    -- Frame rate (store as rational to maintain precision)
        \\    frame_rate_num INT,
        \\    frame_rate_den INT,
        \\    frame_rate_float NUMERIC(10,4),
        \\    
        \\    -- Time base (for timeline calculations)
        \\    time_base_num INT,
        \\    time_base_den INT,
        \\    
        \\    -- Timecode and frame info
        \\    start_timecode TEXT,
        \\    end_timecode TEXT,
        \\    drop_frame BOOLEAN DEFAULT FALSE,
        \\    start_frame_number BIGINT DEFAULT 0,
        \\    end_frame_number BIGINT,
        \\    
        \\    -- Duration
        \\    duration_frames BIGINT,
        \\    
        \\    -- Metadata
        \\    reel_name TEXT,
        \\    color_space TEXT,
        \\    
        \\    created_at TIMESTAMPTZ DEFAULT NOW(),
        \\    modified_at TIMESTAMPTZ DEFAULT NOW()
        \\)
    , .{});

    // Create index
    _ = try conn.exec("CREATE INDEX idx_sources_path ON sources(path)", .{});

    // Create update trigger (if it doesn't exist)
    _ = try conn.exec(
        \\CREATE OR REPLACE FUNCTION update_modified_at()
        \\RETURNS TRIGGER AS $$
        \\BEGIN
        \\    NEW.modified_at = NOW();
        \\    RETURN NEW;
        \\END;
        \\$$ LANGUAGE plpgsql
    , .{});

    _ = try conn.exec(
        \\CREATE TRIGGER update_sources_modified_at
        \\    BEFORE UPDATE ON sources
        \\    FOR EACH ROW
        \\    EXECUTE FUNCTION update_modified_at()
    , .{});

    std.debug.print("✓ Database initialized with new sources schema\n", .{});
}

pub fn resetAndInitializeDatabase(pool: *pg.Pool) !void {
    var conn = try pool.acquire();
    defer conn.release();

    // Drop all dependent tables first (cascade doesn't work with multiple tables)
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

    // Recreate sources table with full schema
    _ = try conn.exec(
        \\CREATE TABLE sources (
        \\    id SERIAL PRIMARY KEY,
        \\    
        \\    -- File metadata
        \\    path TEXT NOT NULL UNIQUE,
        \\    filename TEXT NOT NULL,
        \\    file_modified_at TIMESTAMPTZ,
        \\    file_size_bytes BIGINT,
        \\    
        \\    -- Video codec and format
        \\    codec TEXT,
        \\    
        \\    -- Resolution (display)
        \\    width INT,
        \\    height INT,
        \\    container_width INT,
        \\    container_height INT,
        \\    
        \\    -- Frame rate (store as rational to maintain precision)
        \\    frame_rate_num INT,
        \\    frame_rate_den INT,
        \\    frame_rate_float NUMERIC(10,4),
        \\    
        \\    -- Time base (for timeline calculations)
        \\    time_base_num INT,
        \\    time_base_den INT,
        \\    
        \\    -- Timecode and frame info
        \\    start_timecode TEXT,
        \\    end_timecode TEXT,
        \\    drop_frame BOOLEAN DEFAULT FALSE,
        \\    start_frame_number BIGINT DEFAULT 0,
        \\    end_frame_number BIGINT,
        \\    
        \\    -- Duration
        \\    duration_frames BIGINT,
        \\    
        \\    -- Metadata
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
        \\    source_id INT REFERENCES sources(id) ON DELETE RESTRICT,
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

    // Create or replace update function
    _ = try conn.exec(
        \\CREATE OR REPLACE FUNCTION update_modified_at()
        \\RETURNS TRIGGER AS $$
        \\BEGIN
        \\    NEW.modified_at = NOW();
        \\    RETURN NEW;
        \\END;
        \\$$ LANGUAGE plpgsql
    , .{});

    // Create triggers
    _ = try conn.exec(
        \\DROP TRIGGER IF EXISTS update_projects_modified_at ON projects
    , .{});
    _ = try conn.exec(
        \\CREATE TRIGGER update_projects_modified_at
        \\    BEFORE UPDATE ON projects
        \\    FOR EACH ROW
        \\    EXECUTE FUNCTION update_modified_at()
    , .{});

    _ = try conn.exec(
        \\DROP TRIGGER IF EXISTS update_timelines_modified_at ON timelines
    , .{});
    _ = try conn.exec(
        \\CREATE TRIGGER update_timelines_modified_at
        \\    BEFORE UPDATE ON timelines
        \\    FOR EACH ROW
        \\    EXECUTE FUNCTION update_modified_at()
    , .{});

    _ = try conn.exec(
        \\DROP TRIGGER IF EXISTS update_timeline_clips_modified_at ON timeline_clips
    , .{});
    _ = try conn.exec(
        \\CREATE TRIGGER update_timeline_clips_modified_at
        \\    BEFORE UPDATE ON timeline_clips
        \\    FOR EACH ROW
        \\    EXECUTE FUNCTION update_modified_at()
    , .{});

    _ = try conn.exec(
        \\DROP TRIGGER IF EXISTS update_sources_modified_at ON sources
    , .{});
    _ = try conn.exec(
        \\CREATE TRIGGER update_sources_modified_at
        \\    BEFORE UPDATE ON sources
        \\    FOR EACH ROW
        \\    EXECUTE FUNCTION update_modified_at()
    , .{});

    std.debug.print("✓ Database fully reset and reinitialized with new schema\n", .{});
}
