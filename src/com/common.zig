const std = @import("std");

const toml = @import("toml");

pub const FRAMES_IN_FLIGHT = 2;
pub const MAX_UI_VERTICES = 65536;
pub const MAX_UI_INDICES = 131072;

pub const Constants = struct {
    window_config: []const u8,
    video_path: []const u8,

    use_display_p3: bool,
    use_10bit: bool,

    gpu: []const u8,
    swap_chain_images: u8,
    ups: f32,
    validation: bool,
    vsync: bool,

    pub fn load(io: std.Io, allocator: std.mem.Allocator) !Constants {
        var parser = toml.Parser(Constants).init(allocator);
        defer parser.deinit();

        const result = try parser.parseFile(io, "res/cfg/cfg.toml");
        defer result.deinit();

        const tmp = result.value;

        const constants = Constants{
            .window_config = try allocator.dupe(u8, tmp.window_config),
            .video_path = try allocator.dupe(u8, tmp.video_path),

            .use_display_p3 = tmp.use_display_p3,
            .use_10bit = tmp.use_10bit,

            .gpu = try allocator.dupe(u8, tmp.gpu),
            .swap_chain_images = tmp.swap_chain_images,
            .ups = tmp.ups,
            .validation = tmp.validation,
            .vsync = tmp.vsync,
        };

        return constants;
    }

    pub fn cleanup(self: *Constants, allocator: std.mem.Allocator) void {
        allocator.free(self.gpu);
        allocator.free(self.window_config);
        allocator.free(self.video_path);
    }
};
