const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Config = @import("config.zig").Config;
const Database = @import("io/db/database.zig").Database;
const SourceMedia = @import("io/media/media.zig").SourceMedia;
const Sources = @import("io/media/sources.zig").Sources;
const ProjectManager = @import("io/project/project_manager.zig").ProjectManager;
pub const Playback = @import("playback/playback.zig").Playback;
const VideoMonitor = @import("playback/video_monitor.zig").VideoMonitor;

const log = std.log.scoped(.core);

pub const Core = struct {
    allocator: Allocator,
    io: Io,

    cfg: Config,
    playback: Playback,

    database: *Database,
    project_manager: *ProjectManager,
    sources: *Sources,

    video_monitors: std.ArrayList(VideoMonitor),

    pub fn init(allocator: Allocator, io: Io) !Core {
        // Load and parse all configuration
        const cfg = try Config.load(io, allocator);

        // Initialize database
        const database = try allocator.create(Database);
        database.* = try Database.init(allocator, io);
        errdefer {
            database.deinit();
            allocator.destroy(database);
        }

        // Initialize project manager
        const project_manager = try allocator.create(ProjectManager);
        project_manager.* = ProjectManager.init();
        errdefer {
            project_manager.deinit(allocator);
            allocator.destroy(project_manager);
        }

        // Initialize sources
        const sources = try allocator.create(Sources);
        sources.* = Sources.init();
        errdefer {
            sources.deinit(allocator);
            allocator.destroy(sources);
        }

        // Load default project from config
        const project_id = cfg.constants.default_project_id;
        project_manager.load(database.pool, project_id) catch |err| {
            log.warn("Project {d} not found ({}), no project loaded", .{ project_id, err });
            // Continue without a project - ProjectManager UI will handle this later
        };

        // Hydrate sources from database
        try sources.hydrateFromDb(database.pool, io, allocator);

        // Import test video if project loaded and sources is empty
        if (project_manager.current != null and sources.map.count() == 0) {
            _ = try sources.importFromFile(
                database.pool,
                project_manager.current.?.id,
                cfg.testing.video_path,
                io,
                allocator,
            );
        }

        // Initialize playback state with test in/out points
        const playback: Playback = .{
            .playing = std.atomic.Value(f32).init(0.0),
            .speed = std.atomic.Value(f32).init(1.0),
            .loop = std.atomic.Value(bool).init(true),
            .in_point = cfg.testing.in_point,
            .out_point = cfg.testing.out_point,
        };

        return .{
            .allocator = allocator,
            .io = io,
            .cfg = cfg,
            .playback = playback,
            .database = database,
            .project_manager = project_manager,
            .sources = sources,
            .video_monitors = std.ArrayList(VideoMonitor).empty,
        };
    }

    /// Load first source from Sources and initialize VideoMonitor.
    /// Called after Platform is ready
    pub fn loadSourceMedia(self: *Core) !void {
        // Get first source from sources map
        if (self.sources.map.values().len == 0) {
            return error.NoSourcesAvailable;
        }
        const sm = self.sources.map.values()[0];

        // Initialize VideoMonitor with loaded media
        const video_monitor = try VideoMonitor.init(
            &sm.frame_rate.get(),
            self.io,
            self.allocator,
            &self.playback,
        );
        try self.video_monitors.append(self.allocator, video_monitor);

        log.debug("✓ Core loaded video: {d}x{d} @ {d:.2}fps, {d} frames", .{
            sm.resolution.width,
            sm.resolution.height,
            sm.frame_rate_float,
            sm.duration_in_frames,
        });
    }

    pub fn deinit(self: *Core) void {
        for (self.video_monitors.items) |*vm| vm.deinit();
        self.video_monitors.deinit(self.allocator);

        self.sources.deinit(self.allocator);
        self.allocator.destroy(self.sources);

        self.project_manager.deinit(self.allocator);
        self.allocator.destroy(self.project_manager);

        self.database.deinit();
        self.allocator.destroy(self.database);

        self.cfg.deinit(self.allocator);
    }
};
