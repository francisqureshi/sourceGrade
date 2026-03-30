const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Config = @import("config.zig").Config;
const Database = @import("io/db/database.zig").Database;
const SourceMedia = @import("io/media/media.zig").SourceMedia;
const Sources = @import("io/media/sources.zig").Sources;
const ProjectManager = @import("io/project/project_manager.zig").ProjectManager;
const Session = @import("playback/session.zig").Session;

const log = std.log.scoped(.core);

pub const Core = struct {
    allocator: Allocator,
    io: Io,

    cfg: Config,

    database: *Database,
    project_manager: *ProjectManager,
    sources: *Sources,

    /// Active sessions (UUID -> Session)
    /// Sessions are created on-demand when a viewer loads a source
    sessions: std.AutoArrayHashMapUnmanaged([16]u8, *Session),

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
        };

        // Hydrate sources from database
        try sources.hydrateFromDb(database.pool, io, allocator);

        // Import test videos if project loaded and they don't exist
        if (project_manager.current != null) {
            const test_videos = [_][]const u8{
                cfg.testing.video_path,
                "/Users/fq/Desktop/AGMM/A_0005C014_251204_170032_p1CMW_S01.mov",
            };
            for (test_videos) |video_path| {
                if (!sources.hasPath(video_path)) {
                    _ = try sources.importFromFile(
                        database.pool,
                        project_manager.current.?.id,
                        video_path,
                        io,
                        allocator,
                    );
                }
            }
        }

        return .{
            .allocator = allocator,
            .io = io,
            .cfg = cfg,
            .database = database,
            .project_manager = project_manager,
            .sources = sources,
            .sessions = std.AutoArrayHashMapUnmanaged([16]u8, *Session).empty,
        };
    }

    /// Get or create a session for a source by UUID.
    /// Sessions are reused if already loaded (shared playback state).
    //FIXME: Not 100% on this fn... could we be checking somewhere above and just get or create above?
    pub fn getOrCreateSession(self: *Core, uuid: [16]u8) !*Session {

        // Get source from Sources
        const source = self.sources.get(uuid) orelse return error.SourceNotFound;

        // Allocate and initialize session
        const session = try self.allocator.create(Session);
        errdefer self.allocator.destroy(session);

        try session.init(source, self.io, self.allocator);
        try self.sessions.put(self.allocator, uuid, session);

        return session;
    }

    /// Get session by UUID (returns null if not loaded)
    pub fn getSession(self: *Core, uuid: [16]u8) ?*Session {
        return self.sessions.get(uuid);
    }

    pub fn deinit(self: *Core) void {
        // Clean up all sessions
        for (self.sessions.values()) |session| {
            session.deinit();
            self.allocator.destroy(session);
        }
        self.sessions.deinit(self.allocator);

        self.sources.deinit(self.allocator);
        self.allocator.destroy(self.sources);

        self.project_manager.deinit(self.allocator);
        self.allocator.destroy(self.project_manager);

        self.database.deinit();
        self.allocator.destroy(self.database);

        self.cfg.deinit(self.allocator);
    }
};
