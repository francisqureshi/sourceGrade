const std = @import("std");
const Allocator = std.mem.Allocator;

const pg = @import("pg");

const Project = @import("project.zig").Project;
const pgdb = @import("../db/pgdb.zig");

pub const log = std.log.scoped(.projectManager);

pub const ProjectManager = struct {
    /// Currently active project
    current: ?Project,

    pub fn init() ProjectManager {
        return .{
            .current = null,
        };
    }

    pub fn deinit(self: *ProjectManager, allocator: Allocator) void {
        if (self.current) |*proj| {
            proj.deinit(allocator);
        }
    }

    /// Create a new project and set it as current
    pub fn create(self: *ProjectManager, db_pool: *pg.Pool, name: []const u8, frame_rate: f64) !void {
        const id = try pgdb.createProject(db_pool, name, frame_rate);
        self.current = Project.init(id, name, frame_rate);
        log.debug("Created project: {s} (id: {d})", .{ name, id });
    }

    /// Load an existing project by ID
    pub fn load(self: *ProjectManager, db_pool: *pg.Pool, project_id: i32) !void {
        if (try pgdb.getProjectById(db_pool, project_id)) |db_proj| {
            self.current = Project.init(
                project_id,
                db_proj.name,
                db_proj.frame_rate orelse 24.0,
            );
            log.debug("Loaded project: {s} (id: {d})", .{ db_proj.name, project_id });
        } else {
            return error.ProjectNotFound;
        }
    }

    /// List all projects
    pub fn list(self: *ProjectManager, db_pool: *pg.Pool) !void {
        _ = self;
        try pgdb.listProjects(db_pool);
    }

    /// Delete a project by ID
    pub fn delete(self: *ProjectManager, db_pool: *pg.Pool, project_id: i32) !void {
        // Clear current if deleting active project
        if (self.current) |curr| {
            if (curr.id == project_id) {
                self.current = null;
            }
        }
        try pgdb.deleteProject(db_pool, project_id);
    }
};
