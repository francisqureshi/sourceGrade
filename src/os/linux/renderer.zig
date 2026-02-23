const std = @import("std");

const com = @import("com");
const sdl3 = @import("sdl3");
const vk = @import("vk");

const Platform = @import("platform.zig").Platform;

pub const Render = struct {
    vkCtx: vk.ctx.VkCtx,

    pub fn cleanup(self: *Render, allocator: std.mem.Allocator) !void {
        try self.vkCtx.vkDevice.wait();
        try self.vkCtx.cleanup(allocator);
    }

    pub fn create(allocator: std.mem.Allocator, constants: com.common.Constants, window: sdl3.video.Window) !Render {
        const vkCtx = try vk.ctx.VkCtx.create(allocator, constants, window);
        return .{
            .vkCtx = vkCtx,
        };
    }

    pub fn render(self: *Render, platform: *Platform) !void {
        _ = self;
        _ = platform;
    }
};
