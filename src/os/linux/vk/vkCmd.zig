const std = @import("std");
const vulkan = @import("vulkan");
const vk = @import("mod.zig");

pub const VkCmdPool = struct {
    command_pool: vulkan.CommandPool,

    pub fn create(vk_ctx: *const vk.ctx.VkCtx, queue_family_index: u32, reset_support: bool) !VkCmdPool {
        const createInfo: vulkan.CommandPoolCreateInfo = .{ .queue_family_index = queue_family_index, .flags = .{ .reset_command_buffer_bit = reset_support } };
        const command_pool = try vk_ctx.vk_device.device_proxy.createCommandPool(&createInfo, null);
        return .{ .command_pool = command_pool };
    }

    pub fn cleanup(self: *const VkCmdPool, vk_ctx: *const vk.ctx.VkCtx) void {
        vk_ctx.vk_device.device_proxy.destroyCommandPool(self.command_pool, null);
    }

    pub fn reset(self: *const VkCmdPool, vk_ctx: *const vk.ctx.VkCtx) !void {
        try vk_ctx.vk_device.device_proxy.resetCommandPool(self.command_pool, .{});
    }
};

pub const VkCmdBuff = struct {
    cmd_buff_proxy: vulkan.CommandBufferProxy,
    one_time: bool,

    pub fn create(vk_ctx: *const vk.ctx.VkCtx, vk_cmd_pool: *vk.cmd.VkCmdPool, one_time: bool) !VkCmdBuff {
        const allocateInfo: vulkan.CommandBufferAllocateInfo = .{
            .command_buffer_count = 1,
            .command_pool = vk_cmd_pool.command_pool,
            .level = vulkan.CommandBufferLevel.primary,
        };
        var cmds: [1]vulkan.CommandBuffer = undefined;
        try vk_ctx.vk_device.device_proxy.allocateCommandBuffers(&allocateInfo, &cmds);
        const cmd_buff_proxy = vulkan.CommandBufferProxy.init(cmds[0], vk_ctx.vk_device.device_proxy.wrapper);

        return .{ .cmd_buff_proxy = cmd_buff_proxy, .one_time = one_time };
    }

    pub fn cleanup(self: *const VkCmdBuff, vk_ctx: *const vk.ctx.VkCtx, vk_cmd_pool: *vk.cmd.VkCmdPool) void {
        const cmds = [_]vulkan.CommandBuffer{self.cmd_buff_proxy.handle};
        vk_ctx.vk_device.device_proxy.freeCommandBuffers(vk_cmd_pool.command_pool, cmds.len, &cmds);
    }

    pub fn begin(self: *const VkCmdBuff, vk_ctx: *const vk.ctx.VkCtx) !void {
        const beginInfo: vulkan.CommandBufferBeginInfo = .{ .flags = .{ .one_time_submit_bit = self.one_time } };
        try vk_ctx.vk_device.device_proxy.beginCommandBuffer(self.cmd_buff_proxy.handle, &beginInfo);
    }

    pub fn end(self: *const VkCmdBuff, vk_ctx: *const vk.ctx.VkCtx) !void {
        try vk_ctx.vk_device.device_proxy.endCommandBuffer(self.cmd_buff_proxy.handle);
    }

    pub fn submitAndWait(self: *const VkCmdBuff, vk_ctx: *const vk.ctx.VkCtx, vk_queue: vk.queue.VkQueue) !void {
        const vk_fence = try vk.sync.VkFence.create(vk_ctx);
        defer vk_fence.cleanup(vk_ctx);

        const cmd_buffer_submit_info = [_]vulkan.CommandBufferSubmitInfo{.{
            .device_mask = 0,
            .command_buffer = self.cmd_buff_proxy.handle,
        }};

        const empty_semphs = [_]vulkan.SemaphoreSubmitInfo{};

        try vk_queue.submit(vk_ctx, &cmd_buffer_submit_info, &empty_semphs, &empty_semphs, vk_fence);
        try vk_fence.wait(vk_ctx);
    }
};
