const com = @import("../../com/common.zig");
const Platform = @import("platform.zig").Platform;
const std = @import("std");
const vk = @import("vk/mod.zig");

pub const Render = struct {
    vkCtx: vk.ctx.VkCtx,



    pub fn create(allocator: std.mem.Allocator, constants: com.Constants) !Render {
        const vkCtx = try vk.ctx.VkCtx.create(allocator, constants);
        return .{
            .vkCtx = vkCtx,
        };
    }

    pub fn cleanup(self: *Render, allocator: std.mem.Allocator) !void {
        try self.vkCtx.cleanup(allocator);
    }

    pub fn render(self: *Render, platform: *Platform) !void {
        _ = self;
        _ = platform;
    }
};
