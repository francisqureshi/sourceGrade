const std = @import("std");

const com = @import("com");
const sdl3 = @import("sdl3");
const vk = @import("vk");
const vulkan = @import("vulkan");

const mcach = @import("modelsCache.zig");
const rscn = @import("renderScn.zig");
const wnd = @import("window.zig");
const ui = @import("../../gui/ui.zig");
const ImGuiRenderer = @import("ui_renderer.zig").ImGuiRenderer;

/// Top-level Vulkan renderer. Owns the VkCtx, per-frame sync objects,
/// command pools/buffers, queues, scene pipeline, and models cache.
pub const Render = struct {
    vkCtx: vk.ctx.VkCtx,
    cmdPools: []vk.cmd.VkCmdPool,
    cmdBuffs: []vk.cmd.VkCmdBuff,
    currentFrame: u8,
    fences: []vk.sync.VkFence,
    modelsCache: mcach.ModelsCache,
    queueGraphics: vk.queue.VkQueue,
    queuePresent: vk.queue.VkQueue,
    renderScn: rscn.RenderScn,
    uiRenderer: ImGuiRenderer,
    semsPresComplete: []vk.sync.VkSemaphore,
    semsRenderComplete: []vk.sync.VkSemaphore,

    /// Waits for the device to go idle then destroys all Vulkan resources in
    /// reverse creation order.
    pub fn cleanup(self: *Render, allocator: std.mem.Allocator) !void {
        try self.vkCtx.vkDevice.wait();

        self.uiRenderer.cleanup(&self.vkCtx);
        self.renderScn.cleanup(allocator, &self.vkCtx);

        self.modelsCache.cleanup(allocator, &self.vkCtx);

        for (self.cmdPools) |cmdPool| {
            cmdPool.cleanup(&self.vkCtx);
        }
        allocator.free(self.cmdBuffs);

        defer allocator.free(self.cmdPools);
        for (self.fences) |fence| {
            fence.cleanup(&self.vkCtx);
        }
        defer allocator.free(self.fences);

        self.cleanupSemphs(allocator);

        self.uiRenderer.cleanup(&self.vkCtx);

        try self.vkCtx.cleanup(allocator);
    }

    fn cleanupSemphs(self: *Render, allocator: std.mem.Allocator) void {
        for (self.semsRenderComplete) |sem| {
            sem.cleanup(&self.vkCtx);
        }
        defer allocator.free(self.semsRenderComplete);

        for (self.semsPresComplete) |sem| {
            sem.cleanup(&self.vkCtx);
        }
        defer allocator.free(self.semsPresComplete);
    }

    /// Creates the full Vulkan rendering context: VkCtx, sync objects (fences,
    /// semaphores), command pools/buffers, queues, scene pipeline, and models cache.
    pub fn create(allocator: std.mem.Allocator, io: std.Io, constants: com.common.Constants, window: sdl3.video.Window) !Render {
        const vkCtx = try vk.ctx.VkCtx.create(allocator, constants, window);

        const fences = try allocator.alloc(vk.sync.VkFence, com.common.FRAMES_IN_FLIGHT);
        for (fences) |*fence| {
            fence.* = try vk.sync.VkFence.create(&vkCtx);
        }

        const semsRenderComplete = try allocator.alloc(vk.sync.VkSemaphore, vkCtx.vkSwapChain.imageViews.len);
        for (semsRenderComplete) |*sem| {
            sem.* = try vk.sync.VkSemaphore.create(&vkCtx);
        }

        const semsPresComplete = try allocator.alloc(vk.sync.VkSemaphore, com.common.FRAMES_IN_FLIGHT);
        for (semsPresComplete) |*sem| {
            sem.* = try vk.sync.VkSemaphore.create(&vkCtx);
        }

        const cmdPools = try allocator.alloc(vk.cmd.VkCmdPool, com.common.FRAMES_IN_FLIGHT);
        for (cmdPools) |*cmdPool| {
            cmdPool.* = try vk.cmd.VkCmdPool.create(&vkCtx, vkCtx.vkPhysDevice.queuesInfo.graphics_family, false);
        }

        const cmdBuffs = try allocator.alloc(vk.cmd.VkCmdBuff, com.common.FRAMES_IN_FLIGHT);
        for (cmdBuffs, 0..) |*cmdBuff, i| {
            cmdBuff.* = try vk.cmd.VkCmdBuff.create(&vkCtx, &cmdPools[i], true);
        }

        const queueGraphics = vk.queue.VkQueue.create(&vkCtx, vkCtx.vkPhysDevice.queuesInfo.graphics_family);
        const queuePresent = vk.queue.VkQueue.create(&vkCtx, vkCtx.vkPhysDevice.queuesInfo.present_family);

        const uiRenderer = try ImGuiRenderer.create(allocator, io, &vkCtx);

        const renderScn = try rscn.RenderScn.create(allocator, io, &vkCtx);

        const modelsCache = mcach.ModelsCache.create(allocator);

        return .{
            .vkCtx = vkCtx,
            .cmdPools = cmdPools,
            .cmdBuffs = cmdBuffs,
            .currentFrame = 0,
            .fences = fences,
            .modelsCache = modelsCache,
            .queueGraphics = queueGraphics,
            .queuePresent = queuePresent,
            .renderScn = renderScn,
            .semsPresComplete = semsPresComplete,
            .semsRenderComplete = semsRenderComplete,
            .uiRenderer = uiRenderer,
        };
    }

    /// Uploads initial scene geometry to the GPU via the models cache.
    pub fn init(self: *Render, allocator: std.mem.Allocator, initData: *const com.mdata.InitData) !void {
        try self.modelsCache.init(allocator, &self.vkCtx, &self.cmdPools[0], self.queueGraphics, initData);
    }

    /// Renders one frame: acquires a swapchain image, records and submits draw
    /// commands, then presents. Skips the frame if the window was just resized.
    pub fn render(self: *Render, window: *wnd.Wnd, imgui_ctx: *ui.ImGuiContext) !void {
        // Check resize Before acquiring to avoid leaving semaphore signaled
        if (window.resized) {
            return;
        }

        const fence = self.fences[self.currentFrame];
        try fence.wait(&self.vkCtx);
        try fence.reset(&self.vkCtx);

        const vkCmdPool = self.cmdPools[self.currentFrame];
        try vkCmdPool.reset(&self.vkCtx);

        const vkCmdBuff = self.cmdBuffs[self.currentFrame];
        try vkCmdBuff.begin(&self.vkCtx);

        const res = try self.vkCtx.vkSwapChain.acquire(self.vkCtx.vkDevice, self.semsPresComplete[self.currentFrame]);
        if (res == .recreate) {
            try vkCmdBuff.end(&self.vkCtx);
            self.currentFrame = (self.currentFrame + 1) % com.common.FRAMES_IN_FLIGHT;
            return;
        }
        const imageIndex = res.ok;

        self.renderMainInit(vkCmdBuff, imageIndex);

        try self.renderScn.render(&self.vkCtx, vkCmdBuff, &self.modelsCache, imageIndex);

        try self.uiRenderer.render(&self.vkCtx, vkCmdBuff, imgui_ctx, self.currentFrame, self.vkCtx.vkSwapChain.extent);

        self.renderMainFinish(vkCmdBuff, imageIndex);

        try vkCmdBuff.end(&self.vkCtx);

        try self.submit(&vkCmdBuff, imageIndex);

        _ = self.vkCtx.vkSwapChain.present(self.vkCtx.vkDevice, self.queuePresent, self.semsRenderComplete[imageIndex], imageIndex);

        self.currentFrame = (self.currentFrame + 1) % com.common.FRAMES_IN_FLIGHT;
    }

    /// Records a pipeline barrier transitioning the swapchain image from
    /// `color_attachment_optimal` to `present_src_khr` ready for presentation.
    fn renderMainFinish(self: *Render, vkCmd: vk.cmd.VkCmdBuff, imageIndex: u32) void {
        const endBarriers = [_]vulkan.ImageMemoryBarrier2{.{
            .old_layout = vulkan.ImageLayout.color_attachment_optimal,
            .new_layout = vulkan.ImageLayout.present_src_khr,
            .src_stage_mask = .{ .color_attachment_output_bit = true },
            .dst_stage_mask = .{ .bottom_of_pipe_bit = true },
            .src_access_mask = .{ .color_attachment_write_bit = true },
            .dst_access_mask = .{},
            .src_queue_family_index = vulkan.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vulkan.QUEUE_FAMILY_IGNORED,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = vulkan.REMAINING_MIP_LEVELS,
                .base_array_layer = 0,
                .layer_count = vulkan.REMAINING_ARRAY_LAYERS,
            },
            .image = self.vkCtx.vkSwapChain.imageViews[imageIndex].image,
        }};
        const endDepInfo = vulkan.DependencyInfo{
            .image_memory_barrier_count = endBarriers.len,
            .p_image_memory_barriers = &endBarriers,
        };
        self.vkCtx.vkDevice.deviceProxy.cmdPipelineBarrier2(vkCmd.cmdBuffProxy.handle, &endDepInfo);
    }

    /// Records a pipeline barrier transitioning the swapchain image from
    /// `undefined` to `color_attachment_optimal` ready for rendering.
    fn renderMainInit(self: *Render, vkCmd: vk.cmd.VkCmdBuff, imageIndex: u32) void {
        const initBarriers = [_]vulkan.ImageMemoryBarrier2{.{
            .old_layout = vulkan.ImageLayout.undefined,
            .new_layout = vulkan.ImageLayout.color_attachment_optimal,
            .src_stage_mask = .{ .color_attachment_output_bit = true },
            .dst_stage_mask = .{ .color_attachment_output_bit = true },
            .src_access_mask = .{},
            .dst_access_mask = .{ .color_attachment_write_bit = true },
            .src_queue_family_index = vulkan.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vulkan.QUEUE_FAMILY_IGNORED,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = vulkan.REMAINING_MIP_LEVELS,
                .base_array_layer = 0,
                .layer_count = vulkan.REMAINING_ARRAY_LAYERS,
            },
            .image = self.vkCtx.vkSwapChain.imageViews[imageIndex].image,
        }};
        const initDepInfo = vulkan.DependencyInfo{
            .image_memory_barrier_count = initBarriers.len,
            .p_image_memory_barriers = &initBarriers,
        };
        self.vkCtx.vkDevice.deviceProxy.cmdPipelineBarrier2(vkCmd.cmdBuffProxy.handle, &initDepInfo);
    }

    /// Submits the command buffer to the graphics queue, waiting on the
    /// present-complete semaphore and signalling the render-complete semaphore.
    fn submit(self: *Render, vkCmdBuff: *const vk.cmd.VkCmdBuff, imageIndex: u32) !void {
        const vkFence = self.fences[self.currentFrame];

        const cmdBufferInfo = vulkan.CommandBufferSubmitInfo{
            .device_mask = 0,
            .command_buffer = vkCmdBuff.cmdBuffProxy.handle,
        };

        const semWaitInfo = vulkan.SemaphoreSubmitInfo{
            .device_index = 0,
            .value = 0,
            .stage_mask = .{ .color_attachment_output_bit = true },
            .semaphore = self.semsPresComplete[self.currentFrame].semaphore,
        };

        const semSignalInfo = vulkan.SemaphoreSubmitInfo{
            .device_index = 0,
            .value = 0,
            .stage_mask = .{ .bottom_of_pipe_bit = true },
            .semaphore = self.semsRenderComplete[imageIndex].semaphore,
        };

        try self.queueGraphics.submit(&self.vkCtx, &.{cmdBufferInfo}, &.{semSignalInfo}, &.{semWaitInfo}, vkFence);
    }
};
