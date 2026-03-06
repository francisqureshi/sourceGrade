const std = @import("std");
const vulkan = @import("vulkan");
const vk = @import("mod.zig");

pub const VkFence = struct {
    fence: vulkan.Fence,

    pub fn create(vk_ctx: *const vk.ctx.VkCtx) !VkFence {
        const fence = try vk_ctx.*.vk_device.device_proxy.createFence(&.{ .flags = .{ .signaled_bit = true } }, null);
        return .{ .fence = fence };
    }

    pub fn cleanup(self: *const VkFence, vk_ctx: *const vk.ctx.VkCtx) void {
        vk_ctx.*.vk_device.device_proxy.destroyFence(self.fence, null);
    }

    pub fn reset(self: *const VkFence, vk_ctx: *const vk.ctx.VkCtx) !void {
        try vk_ctx.*.vk_device.device_proxy.resetFences(1, @ptrCast(&self.fence));
    }

    pub fn wait(self: *const VkFence, vk_ctx: *const vk.ctx.VkCtx) !void {
        _ = try vk_ctx.*.vk_device.device_proxy.waitForFences(1, @ptrCast(&self.fence), vulkan.Bool32.true, std.math.maxInt(u64));
    }
};

pub const VkSemaphore = struct {
    semaphore: vulkan.Semaphore,

    pub fn create(vk_ctx: *const vk.ctx.VkCtx) !VkSemaphore {
        const semaphore = try vk_ctx.*.vk_device.device_proxy.createSemaphore(&.{}, null);
        return .{ .semaphore = semaphore };
    }

    pub fn cleanup(self: *const VkSemaphore, vk_ctx: *const vk.ctx.VkCtx) void {
        vk_ctx.*.vk_device.device_proxy.destroySemaphore(self.semaphore, null);
    }
};
