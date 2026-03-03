const vulkan = @import("vulkan");
const vk = @import("mod.zig");

pub const VkQueue = struct {
    handle: vulkan.Queue,
    family: u32,

    /// Retrieves a queue handle from the logical device for the given family index.
    /// Index 0 is used — only one queue per family is requested at device creation.
    pub fn create(vk_ctx: *const vk.ctx.VkCtx, family: u32) VkQueue {
        return .{
            .handle = vk_ctx.vk_device.device_proxy.getDeviceQueue(family, 0),
            .family = family,
        };
    }

    pub fn submit(self: *const VkQueue, vk_ctx: *const vk.ctx.VkCtx, cmd_buffer_submit_info: []const vulkan.CommandBufferSubmitInfo, sem_signal_info: []const vulkan.SemaphoreSubmitInfo, sem_wait_info: []const vulkan.SemaphoreSubmitInfo, vk_fence: vk.sync.VkFence) !void {
        try vk_fence.reset(vk_ctx);
        const si = vulkan.SubmitInfo2{
            .command_buffer_info_count = @as(u32, @intCast(cmd_buffer_submit_info.len)),
            .p_command_buffer_infos = cmd_buffer_submit_info.ptr,
            .signal_semaphore_info_count = @as(u32, @intCast(sem_signal_info.len)),
            .p_signal_semaphore_infos = sem_signal_info.ptr,
            .wait_semaphore_info_count = @as(u32, @intCast(sem_wait_info.len)),
            .p_wait_semaphore_infos = sem_wait_info.ptr,
        };
        try vk_ctx.vk_device.device_proxy.queueSubmit2(
            self.handle,
            1,
            @ptrCast(&si),
            vk_fence.fence,
        );
    }
};
