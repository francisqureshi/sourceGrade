const vulkan = @import("vulkan");
const vk = @import("mod.zig");

pub const VkBuffer = struct {
    size: u64,
    buffer: vulkan.Buffer,
    memory: vulkan.DeviceMemory,

    pub fn create(vk_ctx: *const vk.ctx.VkCtx, size: u64, buffer_usage: vulkan.BufferUsageFlags, mem_flags: vulkan.MemoryPropertyFlags) !VkBuffer {
        const create_info = vulkan.BufferCreateInfo{
            .size = size,
            .usage = buffer_usage,
            .sharing_mode = vulkan.SharingMode.exclusive,
        };
        const buffer = try vk_ctx.vk_device.device_proxy.createBuffer(&create_info, null);

        const mem_reqs = vk_ctx.vk_device.device_proxy.getBufferMemoryRequirements(buffer);

        const alloc_info = vulkan.MemoryAllocateInfo{
            .allocation_size = mem_reqs.size,
            .memory_type_index = try vk_ctx.findMemoryTypeIndex(mem_reqs.memory_type_bits, mem_flags),
        };
        const memory = try vk_ctx.vk_device.device_proxy.allocateMemory(&alloc_info, null);

        try vk_ctx.vk_device.device_proxy.bindBufferMemory(buffer, memory, 0);

        return .{
            .size = size,
            .buffer = buffer,
            .memory = memory,
        };
    }

    pub fn cleanup(self: *const VkBuffer, vk_ctx: *const vk.ctx.VkCtx) void {
        vk_ctx.vk_device.device_proxy.destroyBuffer(self.buffer, null);
        vk_ctx.vk_device.device_proxy.freeMemory(self.memory, null);
    }

    pub fn map(self: *const VkBuffer, vk_ctx: *const vk.ctx.VkCtx) !?*anyopaque {
        return try vk_ctx.vk_device.device_proxy.mapMemory(self.memory, 0, vulkan.WHOLE_SIZE, .{});
    }

    pub fn unMap(self: *const VkBuffer, vk_ctx: *const vk.ctx.VkCtx) void {
        vk_ctx.vk_device.device_proxy.unmapMemory(self.memory);
    }
};
