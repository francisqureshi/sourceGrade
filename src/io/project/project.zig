const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Project = struct {
    id: i32,
    name: []const u8,
    frame_rate: f64,

    pub fn init(allocator: Allocator, id: i32, name: []const u8, frame_rate: f64) !Project {
        return .{
            .id = id,
            .name = try allocator.dupe(u8, name),
            .frame_rate = frame_rate,
        };
    }

    pub fn deinit(self: *Project, allocator: Allocator) void {
        allocator.free(self.name);
    }
};
