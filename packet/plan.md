# Schema & Code Alignment: SourceMedia ↔ Sources Table

## Executive Summary
Align the PostgreSQL `sources` table with the `SourceMedia` struct to ensure complete metadata capture for video files. This includes adding 10+ new columns, renaming for consistency, fixing type mismatches, and creating database access functions.

## Phase 1: Schema Updates (src/io/db/schema.sql)

### 1.1 Drop and Recreate Sources Table

**Current Issues:**
- `frame_rate NUMERIC(10,2)` loses precision (should be rational: num/den)
- `duration_frames INT` - overflow risk on long-form (should be BIGINT)
- Missing container resolution, time_base, drop_frame, frame numbers, end_timecode
- `timecode_start` should be `start_timecode` for consistency
- color_space in DB but not in SourceMedia - keep for future media info

**New Column Structure:**

```sql
CREATE TABLE sources (
    id SERIAL PRIMARY KEY,
    
    -- File metadata
    path TEXT NOT NULL UNIQUE,
    filename TEXT NOT NULL,
    file_modified_at TIMESTAMPTZ,          -- ctx.file.stat.mtime
    file_size_bytes BIGINT,
    
    -- Video codec and format
    codec TEXT,                            -- 'prores_4444', 'h264', etc.
    
    -- Resolution (display)
    width INT,
    height INT,
    container_width INT,                   -- NEW: separate from display
    container_height INT,                  -- NEW: separate from display
    
    -- Frame rate (store as rational to maintain precision)
    frame_rate_num INT,                    -- NEW: numerator
    frame_rate_den INT,                    -- NEW: denominator
    frame_rate_float NUMERIC(10,4),        -- OPTIONAL: cache the float
    
    -- Time base (for timeline calculations)
    time_base_num INT,                     -- NEW: numerator
    time_base_den INT,                     -- NEW: denominator
    
    -- Timecode and frame info
    start_timecode TEXT,                   -- RENAMED from timecode_start
    end_timecode TEXT,                     -- NEW
    drop_frame BOOLEAN DEFAULT FALSE,      -- NEW: critical for timecode math
    start_frame_number BIGINT DEFAULT 0,   -- NEW: where timecode starts
    end_frame_number BIGINT,               -- NEW: where timecode ends
    
    -- Duration
    duration_frames BIGINT,                -- CHANGED: INT -> BIGINT
    
    -- Metadata
    reel_name TEXT,                        -- NEW: for tape-based workflows
    color_space TEXT,                      -- Keep: 'rec709', 'rec2020'
    
    created_at TIMESTAMPTZ DEFAULT NOW(),
    modified_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_sources_path ON sources(path);
```

## Phase 2: Zig Code Updates (src/io/db/pgdb.zig)

### 2.1 Create Source struct (mirrors database schema)

```zig
const Source = struct {
    id: i32,
    path: []const u8,
    filename: []const u8,
    file_modified_at: ?i64,          // TIMESTAMPTZ as Unix microseconds
    file_size_bytes: ?i64,
    
    codec: []const u8,
    
    width: i32,
    height: i32,
    container_width: ?i32,
    container_height: ?i32,
    
    frame_rate_num: i32,
    frame_rate_den: i32,
    frame_rate_float: ?f64,
    
    time_base_num: i32,
    time_base_den: i32,
    
    start_timecode: []const u8,
    end_timecode: ?[]const u8,
    drop_frame: bool,
    start_frame_number: i64,
    end_frame_number: i64,
    
    duration_frames: i64,
    
    reel_name: ?[]const u8,
    color_space: ?[]const u8,
    
    created_at: i64,
    modified_at: i64,
};
```

### 2.2 Add Helper to Convert SourceMedia → Source DB Values

```zig
pub fn sourceMediaToDbValues(
    media: *const SourceMedia,
    file_modified_at: i64,      // from ctx.file.stat.mtime
    file_size_bytes: i64,
) SourceMediaDbValues {
    return SourceMediaDbValues{
        .path = media.file_path,
        .filename = media.file_name,
        .file_modified_at = file_modified_at,
        .file_size_bytes = file_size_bytes,
        .codec = media.codec,
        .width = @intCast(media.resolution.width),
        .height = @intCast(media.resolution.height),
        .container_width = @intCast(media.container_resolution.width),
        .container_height = @intCast(media.container_resolution.height),
        .frame_rate_num = @intCast(media.frame_rate.num),
        .frame_rate_den = @intCast(media.frame_rate.den),
        .frame_rate_float = media.frame_rate_float,
        .time_base_num = @intCast(media.time_base.num),
        .time_base_den = @intCast(media.time_base.den),
        .start_timecode = media.start_timecode,
        .end_timecode = media.end_timecode,
        .drop_frame = media.drop_frame,
        .start_frame_number = media.start_frame_number,
        .end_frame_number = media.end_frame_number,
        .duration_frames = media.duration_in_frames,
        .reel_name = media.reel_name,
    };
}
```

### 2.3 Add Database Access Functions

```zig
pub fn createSource(pool: *pg.Pool, media: *const SourceMedia, ctx: MediaContext) !i32 {
    var conn = try pool.acquire();
    defer conn.release();
    
    // Get file stat for modified time and size
    const stat = try ctx.file.stat(ctx.io);
    const file_mtime = stat.mtime;  // nanoseconds since epoch
    const file_size = stat.size;
    
    const result = try conn.query(
        \\INSERT INTO sources 
        \\  (path, filename, file_modified_at, file_size_bytes, codec,
        \\   width, height, container_width, container_height,
        \\   frame_rate_num, frame_rate_den, frame_rate_float,
        \\   time_base_num, time_base_den,
        \\   start_timecode, end_timecode, drop_frame,
        \\   start_frame_number, end_frame_number,
        \\   duration_frames, reel_name, color_space)
        \\VALUES ($1, $2, to_timestamp($3::bigint / 1000000.0), $4, $5,
        \\        $6, $7, $8, $9,
        \\        $10, $11, $12,
        \\        $13, $14,
        \\        $15, $16, $17,
        \\        $18, $19,
        \\        $20, $21, $22)
        \\RETURNING id
    , .{
        media.file_path, media.file_name, file_mtime, file_size, media.codec,
        @as(i32, @intCast(media.resolution.width)), 
        @as(i32, @intCast(media.resolution.height)),
        @as(i32, @intCast(media.container_resolution.width)),
        @as(i32, @intCast(media.container_resolution.height)),
        @as(i32, @intCast(media.frame_rate.num)),
        @as(i32, @intCast(media.frame_rate.den)),
        media.frame_rate_float,
        @as(i32, @intCast(media.time_base.num)),
        @as(i32, @intCast(media.time_base.den)),
        media.start_timecode, media.end_timecode, media.drop_frame,
        media.start_frame_number, media.end_frame_number,
        media.duration_in_frames,
        media.reel_name,
        null, // color_space - todo: extract from media or config
    });
    defer result.deinit();
    
    if (try result.next()) |row| {
        return row.get(i32, 0);
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
        .time_base_num = row.getCol(i32, "time_base_num"),
        .time_base_den = row.getCol(i32, "time_base_den"),
        .start_timecode = row.getCol([]const u8, "start_timecode"),
        .end_timecode = row.getCol(?[]const u8, "end_timecode"),
        .drop_frame = row.getCol(bool, "drop_frame"),
        .start_frame_number = row.getCol(i64, "start_frame_number"),
        .end_frame_number = row.getCol(i64, "end_frame_number"),
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
        const fps = @as(f32, @floatFromInt(source.frame_rate_num)) / 
                    @as(f32, @floatFromInt(source.frame_rate_den));
        std.debug.print(
            "ID: {d} | {s} | {d}x{d} | {d} frames @ {d:.2}fps | {s}\n",
            .{ source.id, source.filename, source.width, source.height, 
               source.duration_frames, fps, source.codec },
        );
    }
}
```

## Phase 3: Migration Strategy

Since we can't modify PostgreSQL on the fly, the implementation is:

1. **For development/testing:** Drop and recreate the sources table with the new schema
2. **For production:** Would need migrations with ALTER TABLE statements (outside scope here)
3. **Create a db reset/init script** in main.zig to set up fresh schema

## Phase 4: Integration & Testing

### 4.1 Test in main.zig

```zig
fn testSourceIntegration() !void {
    // ... existing setup ...
    
    // Open a video file
    const file = try Io.Dir.openFileAbsolute(io, "/path/to/video.mov", .{});
    defer file.close(io);
    
    const ctx = MediaContext{ .file = file, .io = io, .allocator = allocator };
    
    // Parse media
    var media = try SourceMedia.init(ctx);
    defer media.deinit(allocator);
    
    // Store in database
    const source_id = try pgdb.createSource(pool, &media, ctx);
    std.debug.print("Created source ID: {d}\n", .{source_id});
    
    // Retrieve and verify
    const retrieved = try pgdb.getSourceById(pool, source_id);
    // ... verify fields match ...
}
```

## Files Modified

1. `src/io/db/schema.sql` - Replace sources table definition
2. `src/io/db/pgdb.zig` - Add Source struct + 3 functions
3. `src/main.zig` - Add testSourceIntegration() call in testPgsql()

## Success Criteria

- ✅ All SourceMedia fields mapped to database columns
- ✅ File timestamps captured via ctx.file.stat.mtime
- ✅ Rational numbers (frame_rate, time_base) stored as num/den
- ✅ createSource() returns id on success
- ✅ getSourceById() retrieves all fields correctly
- ✅ Round-trip test: SourceMedia → DB → retrieve → verify
