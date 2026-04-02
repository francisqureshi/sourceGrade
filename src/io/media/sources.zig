const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const pg = @import("pg");

const media = @import("media.zig");
const pgdb = @import("../db/pgdb.zig");

pub const log = std.log.scoped(.sources);

pub const Sources = struct {
    /// Hashmap of dbUUID paired SourcePoolAllocater Source Medias
    map: std.AutoArrayHashMapUnmanaged([16]u8, *media.SourceMedia),

    pub fn init() Sources {
        return .{
            .map = std.AutoArrayHashMapUnmanaged([16]u8, *media.SourceMedia).empty,
        };
    }

    pub fn deinit(self: *Sources, allocator: Allocator) void {
        // Free all SourceMedia objects
        for (self.map.values()) |source_media| {
            source_media.deinit();
            allocator.destroy(source_media);
        }
        self.map.deinit(allocator);
    }

    pub fn add(self: *Sources, allocator: Allocator, uuid: [16]u8, source_media: *media.SourceMedia) !void {
        try self.map.put(allocator, uuid, source_media);
    }

    pub fn get(self: *Sources, uuid: [16]u8) ?*media.SourceMedia {
        return self.map.get(uuid);
    }

    /// Check if a source with this file path already exists
    pub fn hasPath(self: *Sources, file_path: []const u8) bool {
        for (self.map.values()) |sm| {
            if (std.mem.eql(u8, sm.file_path, file_path)) return true;
        }
        return false;
    }

    /// Import a source from file path, add to DB and map
    pub fn importFromFile(
        self: *Sources,
        db_pool: *pg.Pool,
        project_id: i32,
        file_path: []const u8,
        io: Io,
        allocator: Allocator,
    ) !*media.SourceMedia {
        // Create SourceMedia from file
        const source_media = try allocator.create(media.SourceMedia);
        errdefer allocator.destroy(source_media);

        source_media.* = try media.SourceMedia.init(file_path, io, allocator);
        errdefer source_media.deinit();

        // Persist to database (this also sets the UUID on source_media)
        const uuid = try pgdb.createSource(db_pool, project_id, source_media);

        // Add to map
        try self.map.put(allocator, uuid, source_media);

        log.debug("Imported source: {s} ({d}x{d})", .{
            source_media.file_name,
            source_media.resolution.width,
            source_media.resolution.height,
        });

        return source_media;
    }

    /// Hydrate Sources from database
    pub fn hydrateFromDb(self: *Sources, db_pool: *pg.Pool, io: Io, allocator: Allocator) !void {
        var conn = try db_pool.acquire();
        defer conn.release();

        var result = try conn.queryOpts(
            \\SELECT id, path
            \\FROM sources
            \\ORDER BY created_at ASC
        , .{}, .{ .column_names = true });
        defer result.deinit();

        log.debug("=== Rehydrated Sources ===", .{});

        var mapper = result.mapper(struct {
            id: []const u8,
            path: []const u8,
        }, .{ .dupe = true });

        while (try mapper.next()) |db_source| {
            const uuid: [16]u8 = db_source.id[0..16].*;

            // Heap allocate hydrated to SourcePoolAllocator
            const source_media = try allocator.create(media.SourceMedia);

            source_media.* = try media.SourceMedia.initFromDb(uuid, db_source.path, io, allocator);
            try self.map.put(allocator, uuid, source_media);

            log.debug("source_media size: {d} bytes", .{source_media.totalSize()});

            const printable_hex_id = try pg.uuidToHex(db_source.id);
            log.debug(
                "ID: {s} | {s} | {d}x{d} | {d} frames @ {d:.2}fps | {s}",
                .{ &printable_hex_id, source_media.file_name, source_media.resolution.width, source_media.resolution.height, source_media.duration_in_frames, source_media.frame_rate_float, source_media.codec },
            );
        }
    }
};
