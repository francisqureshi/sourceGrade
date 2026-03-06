const std = @import("std");

const vk = @import("vk");
const vulkan = @import("vulkan");

const com = @import("com");

const log = std.log.scoped(.modelsCache);

/// GPU-resident mesh: index buffer, vertex buffer, and draw metadata.
pub const VulkanMesh = struct {
    buff_idx: vk.buf.VkBuffer,
    buff_vtx: vk.buf.VkBuffer,
    id: []const u8,
    num_indices: usize,

    pub fn cleanup(self: *const VulkanMesh, vk_ctx: *const vk.ctx.VkCtx) void {
        self.buff_vtx.cleanup(vk_ctx);
        self.buff_idx.cleanup(vk_ctx);
    }
};

/// A named collection of GPU-resident meshes.
pub const VulkanModel = struct {
    id: []const u8,
    meshes: std.ArrayList(VulkanMesh),

    pub fn cleanup(self: *VulkanModel, allocator: std.mem.Allocator, vk_ctx: *const vk.ctx.VkCtx) void {
        for (self.meshes.items) |mesh| {
            mesh.cleanup(vk_ctx);
        }
        self.meshes.deinit(allocator);
    }
};

/// Hash map of model ID → `VulkanModel`. Owns all GPU buffer memory.
pub const ModelsCache = struct {
    models_map: std.StringHashMap(VulkanModel),

    /// Destroys all GPU buffers for every cached model and frees the map.
    pub fn cleanup(self: *ModelsCache, allocator: std.mem.Allocator, vk_ctx: *const vk.ctx.VkCtx) void {
        var iter = self.models_map.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.cleanup(allocator, vk_ctx);
        }
        self.models_map.deinit();
    }

    /// Returns an empty models cache backed by the given allocator.
    pub fn create(allocator: std.mem.Allocator) ModelsCache {
        const models_map = std.StringHashMap(VulkanModel).init(allocator);
        return .{
            .models_map = models_map,
        };
    }

    /// Uploads all meshes from `init_data` to the GPU using staging buffers,
    /// then stores the resulting `VulkanModel` entries in the cache.
    pub fn init(
        self: *ModelsCache,
        allocator: std.mem.Allocator,
        vk_ctx: *const vk.ctx.VkCtx,
        cmd_pool: *vk.cmd.VkCmdPool,
        vk_queue: vk.queue.VkQueue,
        init_data: *const com.mdata.Init,
    ) !void {
        log.debug("Loading {d} model(s)", .{init_data.models.len});

        const cmd_buff = try vk.cmd.VkCmdBuff.create(vk_ctx, cmd_pool, true);

        var src_buffers = try std.ArrayList(vk.buf.VkBuffer).initCapacity(allocator, 1);
        defer src_buffers.deinit(allocator);
        try cmd_buff.begin(vk_ctx);
        const cmd_handle = cmd_buff.cmd_buff_proxy.handle;

        for (init_data.models) |*model_data| {
            var vulkan_meshes = try std.ArrayList(VulkanMesh).initCapacity(allocator, model_data.meshes.len);

            for (model_data.meshes) |mesh_data| {
                const vertices_size = mesh_data.vertices.len * @sizeOf(f32);
                const src_vtx_buffer = try vk.buf.VkBuffer.create(
                    vk_ctx,
                    vertices_size,
                    vulkan.BufferUsageFlags{ .transfer_src_bit = true },
                    vulkan.MemoryPropertyFlags{ .host_visible_bit = true, .host_coherent_bit = true },
                );
                try src_buffers.append(allocator, src_vtx_buffer);
                const dst_vtx_buffer = try vk.buf.VkBuffer.create(
                    vk_ctx,
                    vertices_size,
                    vulkan.BufferUsageFlags{ .vertex_buffer_bit = true, .transfer_dst_bit = true },
                    vulkan.MemoryPropertyFlags{ .device_local_bit = true },
                );

                const data_vertices = try src_vtx_buffer.map(vk_ctx);
                const gpu_vertices: [*]f32 = @ptrCast(@alignCast(data_vertices));
                @memcpy(gpu_vertices, mesh_data.vertices[0..]);
                src_vtx_buffer.unMap(vk_ctx);

                const indices_size = mesh_data.indices.len * @sizeOf(u32);
                const src_idx_buffer = try vk.buf.VkBuffer.create(
                    vk_ctx,
                    indices_size,
                    vulkan.BufferUsageFlags{ .transfer_src_bit = true },
                    vulkan.MemoryPropertyFlags{ .host_visible_bit = true, .host_coherent_bit = true },
                );
                try src_buffers.append(allocator, src_idx_buffer);
                const dst_idx_buffer = try vk.buf.VkBuffer.create(
                    vk_ctx,
                    indices_size,
                    vulkan.BufferUsageFlags{ .index_buffer_bit = true, .transfer_dst_bit = true },
                    vulkan.MemoryPropertyFlags{ .device_local_bit = true },
                );

                const data_indices = try src_idx_buffer.map(vk_ctx);
                const gpu_indices: [*]u32 = @ptrCast(@alignCast(data_indices));
                @memcpy(gpu_indices, mesh_data.indices[0..]);
                src_idx_buffer.unMap(vk_ctx);

                const vulkan_mesh = VulkanMesh{
                    .buff_idx = dst_idx_buffer,
                    .buff_vtx = dst_vtx_buffer,
                    .id = mesh_data.id,
                    .num_indices = mesh_data.indices.len,
                };
                try vulkan_meshes.append(allocator, vulkan_mesh);

                recordTransfer(vk_ctx, cmd_handle, &src_vtx_buffer, &dst_vtx_buffer);
                recordTransfer(vk_ctx, cmd_handle, &src_idx_buffer, &dst_idx_buffer);
            }

            const vulkan_model = VulkanModel{ .id = model_data.id, .meshes = vulkan_meshes };
            try self.models_map.put(try allocator.dupe(u8, model_data.id), vulkan_model);
        }

        try cmd_buff.end(vk_ctx);
        try cmd_buff.submitAndWait(vk_ctx, vk_queue);

        for (src_buffers.items) |vk_buff| {
            vk_buff.cleanup(vk_ctx);
        }

        log.debug("Loaded {d} model(s)", .{init_data.models.len});
    }
};

fn recordTransfer(
    vk_ctx: *const vk.ctx.VkCtx,
    cmd_handle: vulkan.CommandBuffer,
    src_buff: *const vk.buf.VkBuffer,
    dst_buff: *const vk.buf.VkBuffer,
) void {
    const copy_region = [_]vulkan.BufferCopy{.{
        .src_offset = 0,
        .dst_offset = 0,
        .size = src_buff.size,
    }};
    vk_ctx.vk_device.device_proxy.cmdCopyBuffer(cmd_handle, src_buff.buffer, dst_buff.buffer, copy_region.len, &copy_region);
}
