const std = @import("std");

const vk = @import("vk");
const vulkan = @import("vulkan");

const com = @import("com");

const log = std.log.scoped(.modelsCache);

/// GPU-resident mesh: index buffer, vertex buffer, and draw metadata.
pub const VulkanMesh = struct {
    buffIdx: vk.buf.VkBuffer,
    buffVtx: vk.buf.VkBuffer,
    id: []const u8,
    numIndices: usize,

    pub fn cleanup(self: *const VulkanMesh, vkCtx: *const vk.ctx.VkCtx) void {
        self.buffVtx.cleanup(vkCtx);
        self.buffIdx.cleanup(vkCtx);
    }
};

/// A named collection of GPU-resident meshes.
pub const VulkanModel = struct {
    id: []const u8,
    meshes: std.ArrayList(VulkanMesh),

    pub fn cleanup(self: *VulkanModel, allocator: std.mem.Allocator, vkCtx: *const vk.ctx.VkCtx) void {
        for (self.meshes.items) |mesh| {
            mesh.cleanup(vkCtx);
        }
        self.meshes.deinit(allocator);
    }
};

/// Hash map of model ID → `VulkanModel`. Owns all GPU buffer memory.
pub const ModelsCache = struct {
    modelsMap: std.StringHashMap(VulkanModel),

    /// Destroys all GPU buffers for every cached model and frees the map.
    pub fn cleanup(self: *ModelsCache, allocator: std.mem.Allocator, vkCtx: *const vk.ctx.VkCtx) void {
        var iter = self.modelsMap.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.cleanup(allocator, vkCtx);
        }
        self.modelsMap.deinit();
    }

    /// Returns an empty models cache backed by the given allocator.
    pub fn create(allocator: std.mem.Allocator) ModelsCache {
        const modelsMap = std.StringHashMap(VulkanModel).init(allocator);
        return .{
            .modelsMap = modelsMap,
        };
    }

    /// Uploads all meshes from `initData` to the GPU using staging buffers,
    /// then stores the resulting `VulkanModel` entries in the cache.
    pub fn init(
        self: *ModelsCache,
        allocator: std.mem.Allocator,
        vkCtx: *const vk.ctx.VkCtx,
        cmdPool: *vk.cmd.VkCmdPool,
        vkQueue: vk.queue.VkQueue,
        initData: *const com.mdata.InitData,
    ) !void {
        log.debug("Loading {d} model(s)", .{initData.models.len});

        const cmdBuff = try vk.cmd.VkCmdBuff.create(vkCtx, cmdPool, true);

        var srcBuffers = try std.ArrayList(vk.buf.VkBuffer).initCapacity(allocator, 1);
        defer srcBuffers.deinit(allocator);
        try cmdBuff.begin(vkCtx);
        const cmdHandle = cmdBuff.cmdBuffProxy.handle;

        for (initData.models) |*modelData| {
            var vulkanMeshes = try std.ArrayList(VulkanMesh).initCapacity(allocator, modelData.meshes.len);

            for (modelData.meshes) |meshData| {
                const verticesSize = meshData.vertices.len * @sizeOf(f32);
                const srcVtxBuffer = try vk.buf.VkBuffer.create(
                    vkCtx,
                    verticesSize,
                    vulkan.BufferUsageFlags{ .transfer_src_bit = true },
                    vulkan.MemoryPropertyFlags{ .host_visible_bit = true, .host_coherent_bit = true },
                );
                try srcBuffers.append(allocator, srcVtxBuffer);
                const dstVtxBuffer = try vk.buf.VkBuffer.create(
                    vkCtx,
                    verticesSize,
                    vulkan.BufferUsageFlags{ .vertex_buffer_bit = true, .transfer_dst_bit = true },
                    vulkan.MemoryPropertyFlags{ .device_local_bit = true },
                );

                const dataVertices = try srcVtxBuffer.map(vkCtx);
                const gpuVertices: [*]f32 = @ptrCast(@alignCast(dataVertices));
                @memcpy(gpuVertices, meshData.vertices[0..]);
                srcVtxBuffer.unMap(vkCtx);

                const indicesSize = meshData.indices.len * @sizeOf(u32);
                const srcIdxBuffer = try vk.buf.VkBuffer.create(
                    vkCtx,
                    indicesSize,
                    vulkan.BufferUsageFlags{ .transfer_src_bit = true },
                    vulkan.MemoryPropertyFlags{ .host_visible_bit = true, .host_coherent_bit = true },
                );
                try srcBuffers.append(allocator, srcIdxBuffer);
                const dstIdxBuffer = try vk.buf.VkBuffer.create(
                    vkCtx,
                    indicesSize,
                    vulkan.BufferUsageFlags{ .index_buffer_bit = true, .transfer_dst_bit = true },
                    vulkan.MemoryPropertyFlags{ .device_local_bit = true },
                );

                const dataIndices = try srcIdxBuffer.map(vkCtx);
                const gpuIndices: [*]u32 = @ptrCast(@alignCast(dataIndices));
                @memcpy(gpuIndices, meshData.indices[0..]);
                srcIdxBuffer.unMap(vkCtx);

                const vulkanMesh = VulkanMesh{
                    .buffIdx = dstIdxBuffer,
                    .buffVtx = dstVtxBuffer,
                    .id = meshData.id,
                    .numIndices = meshData.indices.len,
                };
                try vulkanMeshes.append(allocator, vulkanMesh);

                recordTransfer(vkCtx, cmdHandle, &srcVtxBuffer, &dstVtxBuffer);
                recordTransfer(vkCtx, cmdHandle, &srcIdxBuffer, &dstIdxBuffer);
            }

            const vulkanModel = VulkanModel{ .id = modelData.id, .meshes = vulkanMeshes };
            try self.modelsMap.put(try allocator.dupe(u8, modelData.id), vulkanModel);
        }

        try cmdBuff.end(vkCtx);
        try cmdBuff.submitAndWait(vkCtx, vkQueue);

        for (srcBuffers.items) |vkBuff| {
            vkBuff.cleanup(vkCtx);
        }

        log.debug("Loaded {d} model(s)", .{initData.models.len});
    }
};

fn recordTransfer(
    vkCtx: *const vk.ctx.VkCtx,
    cmdHandle: vulkan.CommandBuffer,
    srcBuff: *const vk.buf.VkBuffer,
    dstBuff: *const vk.buf.VkBuffer,
) void {
    const copyRegion = [_]vulkan.BufferCopy{.{
        .src_offset = 0,
        .dst_offset = 0,
        .size = srcBuff.size,
    }};
    vkCtx.vkDevice.deviceProxy.cmdCopyBuffer(cmdHandle, srcBuff.buffer, dstBuff.buffer, copyRegion.len, &copyRegion);
}
