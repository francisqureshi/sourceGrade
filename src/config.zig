const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const com = @import("com");

const app = @import("app.zig");

/// Application configuration, parsed from TOML and command-line args
pub const Config = struct {
    constants: com.common.Constants,
    window: app.WindowConfig,
    testing: TestingConfig,

    pub fn load(io: Io, allocator: Allocator) !Config {
        const constants = try com.common.Constants.load(io, allocator);
        errdefer constants.cleanup(allocator);

        return .{
            .constants = constants,
            .window = parseWndCfg(constants.window_config),
            .testing = .{
                .video_path = constants.video_path,
                .video_path_two = constants.video_path_two,
                .in_point = 15, // Hard coded debug vals
                .out_point = 450,
            },
        };
    }

    pub fn deinit(self: *Config, allocator: Allocator) void {
        self.constants.cleanup(allocator);
    }

    /// Parse window config string from TOML ("1600x900" or "maximised")
    fn parseWndCfg(cfg: []const u8) app.WindowConfig {
        if (std.mem.eql(u8, cfg, "maximised")) {
            return .maximised;
        } else {
            // Parse "1600x900" format
            var split = std.mem.splitScalar(u8, cfg, 'x');
            const width_str = split.first();
            const height_str = split.next() orelse "900"; // Fallback

            const width = std.fmt.parseInt(u32, width_str, 10) catch 1600;
            const height = std.fmt.parseInt(u32, height_str, 10) catch 900;

            return .{
                .specific_size = .{
                    .width = width,
                    .height = height,
                },
            };
        }
    }
};

/// Temporary testing configuration
/// FIXME: Remove when proper media loading is implemented
pub const TestingConfig = struct {
    video_path: []const u8,
    video_path_two: []const u8,
    in_point: isize,
    out_point: isize,
};
