const std = @import("std");

const toml = @import("toml");

pub const FRAMES_IN_FLIGHT = 2;
pub const MAX_UI_VERTICES = 65536;
pub const MAX_UI_INDICES = 131072;

pub const Constants = struct {
    gpu: []const u8,
    swap_chain_images: u8,
    ups: f32,
    validation: bool,
    vsync: bool,
    // windowConfig: bool,

    pub fn load(io: std.Io, allocator: std.mem.Allocator) !Constants {
        var parser = toml.Parser(Constants).init(allocator);
        defer parser.deinit();

        const result = try parser.parseFile(io, "res/cfg/cfg.toml");
        defer result.deinit();

        const tmp = result.value;

        const constants = Constants{
            .gpu = try allocator.dupe(u8, tmp.gpu),
            .swap_chain_images = tmp.swap_chain_images,
            .ups = tmp.ups,
            .validation = tmp.validation,
            .vsync = tmp.vsync,
            // .windowConfig = tmp.windowConfig,
        };

        return constants;
    }

    pub fn cleanup(self: *Constants, allocator: std.mem.Allocator) void {
        allocator.free(self.gpu);
    }
};
