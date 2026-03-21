const std = @import("std");

const toml = @import("toml");

pub const FRAMES_IN_FLIGHT = 2;
pub const MAX_UI_VERTICES = 65536;
pub const MAX_UI_INDICES = 131072;

pub const Constants = struct {
    // General
    window_config: []const u8,
    video_path: []const u8,

    // Metal (macOS)
    metal_use_display_p3: bool,
    metal_use_10bit: bool,

    // Vulkan (Linux)
    vulkan_gpu: []const u8,
    vulkan_swap_chain_images: u8,
    vulkan_validation: bool,

    // Shared rendering
    vsync: bool,
    ups: f32,

    pub fn load(io: std.Io, allocator: std.mem.Allocator) !Constants {
        var parser = toml.Parser(Constants).init(allocator);
        defer parser.deinit();

        const result = try parser.parseFile(io, "res/cfg/cfg.toml");
        defer result.deinit();

        const tmp = result.value;

        const constants = Constants{
            .window_config = try allocator.dupe(u8, tmp.window_config),
            .video_path = try allocator.dupe(u8, tmp.video_path),

            .metal_use_display_p3 = tmp.metal_use_display_p3,
            .metal_use_10bit = tmp.metal_use_10bit,

            .vulkan_gpu = try allocator.dupe(u8, tmp.vulkan_gpu),
            .vulkan_swap_chain_images = tmp.vulkan_swap_chain_images,
            .vulkan_validation = tmp.vulkan_validation,

            .vsync = tmp.vsync,
            .ups = tmp.ups,
        };

        return constants;
    }

    pub fn cleanup(self: *Constants, allocator: std.mem.Allocator) void {
        allocator.free(self.window_config);
        allocator.free(self.video_path);
        allocator.free(self.vulkan_gpu);
    }
};
