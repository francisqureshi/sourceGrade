const std = @import("std");

const com = @import("com");
const sdl3 = @import("sdl3");
const vk = @import("vk");
const vulkan = @import("vulkan");

const mcach = @import("modelsCache.zig");
const rscn = @import("renderScn.zig");
const wnd = @import("window.zig");
const ui = @import("../../ui/ui.zig");
const ImGuiRenderer = @import("ui_renderer.zig").ImGuiRenderer;

/// Top-level Vulkan renderer. Owns the VkCtx, per-frame sync objects,
/// command pools/buffers, queues, scene pipeline, and models cache.
pub const Render = struct {
    vk_ctx: vk.ctx.VkCtx,
    cmd_pools: []vk.cmd.VkCmdPool,
    cmd_buffs: []vk.cmd.VkCmdBuff,
    current_frame: u8,
    fences: []vk.sync.VkFence,
    models_cache: mcach.ModelsCache,
    queue_graphics: vk.queue.VkQueue,
    queue_present: vk.queue.VkQueue,
    render_scn: rscn.RenderScn,
    ui_renderer: ImGuiRenderer,
    sems_pres_complete: []vk.sync.VkSemaphore,
    sems_render_complete: []vk.sync.VkSemaphore,

    /// Waits for the device to go idle then destroys all Vulkan resources in
    /// reverse creation order.
    pub fn cleanup(self: *Render, allocator: std.mem.Allocator) !void {
        try self.vk_ctx.vk_device.wait();

        self.ui_renderer.cleanup(&self.vk_ctx);
        self.render_scn.cleanup(allocator, &self.vk_ctx);

        self.models_cache.cleanup(allocator, &self.vk_ctx);

        for (self.cmd_pools) |cmd_pool| {
            cmd_pool.cleanup(&self.vk_ctx);
        }
        allocator.free(self.cmd_buffs);

        defer allocator.free(self.cmd_pools);
        for (self.fences) |fence| {
            fence.cleanup(&self.vk_ctx);
        }
        defer allocator.free(self.fences);

        self.cleanupSemphs(allocator);

        try self.vk_ctx.cleanup(allocator);
    }

    fn cleanupSemphs(self: *Render, allocator: std.mem.Allocator) void {
        for (self.sems_render_complete) |sem| {
            sem.cleanup(&self.vk_ctx);
        }
        defer allocator.free(self.sems_render_complete);

        for (self.sems_pres_complete) |sem| {
            sem.cleanup(&self.vk_ctx);
        }
        defer allocator.free(self.sems_pres_complete);
    }

    /// Creates the full Vulkan rendering context: VkCtx, sync objects (fences,
    /// semaphores), command pools/buffers, queues, scene pipeline, and models cache.
    pub fn create(allocator: std.mem.Allocator, io: std.Io, constants: com.common.Constants, window: sdl3.video.Window) !Render {
        const vk_ctx = try vk.ctx.VkCtx.create(allocator, constants, window);

        const fences = try allocator.alloc(vk.sync.VkFence, com.common.FRAMES_IN_FLIGHT);
        for (fences) |*fence| {
            fence.* = try vk.sync.VkFence.create(&vk_ctx);
        }

        const sems_render_complete = try allocator.alloc(vk.sync.VkSemaphore, vk_ctx.vk_swap_chain.image_views.len);
        for (sems_render_complete) |*sem| {
            sem.* = try vk.sync.VkSemaphore.create(&vk_ctx);
        }

        const sems_pres_complete = try allocator.alloc(vk.sync.VkSemaphore, com.common.FRAMES_IN_FLIGHT);
        for (sems_pres_complete) |*sem| {
            sem.* = try vk.sync.VkSemaphore.create(&vk_ctx);
        }

        const cmd_pools = try allocator.alloc(vk.cmd.VkCmdPool, com.common.FRAMES_IN_FLIGHT);
        for (cmd_pools) |*cmd_pool| {
            cmd_pool.* = try vk.cmd.VkCmdPool.create(&vk_ctx, vk_ctx.vk_phys_device.queues_info.graphics_family, false);
        }

        const cmd_buffs = try allocator.alloc(vk.cmd.VkCmdBuff, com.common.FRAMES_IN_FLIGHT);
        for (cmd_buffs, 0..) |*cmd_buff, i| {
            cmd_buff.* = try vk.cmd.VkCmdBuff.create(&vk_ctx, &cmd_pools[i], true);
        }

        const queue_graphics = vk.queue.VkQueue.create(&vk_ctx, vk_ctx.vk_phys_device.queues_info.graphics_family);
        const queue_present = vk.queue.VkQueue.create(&vk_ctx, vk_ctx.vk_phys_device.queues_info.present_family);

        const ui_renderer = try ImGuiRenderer.create(allocator, io, &vk_ctx, &cmd_pools[0], queue_graphics);

        const render_scn = try rscn.RenderScn.create(allocator, io, &vk_ctx);

        const models_cache = mcach.ModelsCache.create(allocator);

        return .{
            .vk_ctx = vk_ctx,
            .cmd_pools = cmd_pools,
            .cmd_buffs = cmd_buffs,
            .current_frame = 0,
            .fences = fences,
            .models_cache = models_cache,
            .queue_graphics = queue_graphics,
            .queue_present = queue_present,
            .render_scn = render_scn,
            .sems_pres_complete = sems_pres_complete,
            .sems_render_complete = sems_render_complete,
            .ui_renderer = ui_renderer,
        };
    }

    /// Uploads initial scene geometry to the GPU via the models cache.
    pub fn init(self: *Render, allocator: std.mem.Allocator, init_data: *const com.mdata.Init) !void {
        try self.models_cache.init(allocator, &self.vk_ctx, &self.cmd_pools[0], self.queue_graphics, init_data);
    }

    /// Renders one frame: acquires a swapchain image, records and submits draw
    /// commands, then presents. Skips the frame if the window was just resized.
    pub fn render(self: *Render, window: *wnd.Wnd, imgui_ctx: *ui.ImGui) !void {
        // Check resize Before acquiring to avoid leaving semaphore signaled
        if (window.resized) {
            return;
        }

        const fence = self.fences[self.current_frame];
        try fence.wait(&self.vk_ctx);
        try fence.reset(&self.vk_ctx);

        const vk_cmd_pool = self.cmd_pools[self.current_frame];
        try vk_cmd_pool.reset(&self.vk_ctx);

        const vk_cmd_buff = self.cmd_buffs[self.current_frame];
        try vk_cmd_buff.begin(&self.vk_ctx);

        const res = try self.vk_ctx.vk_swap_chain.acquire(self.vk_ctx.vk_device, self.sems_pres_complete[self.current_frame]);
        if (res == .recreate) {
            try vk_cmd_buff.end(&self.vk_ctx);
            self.current_frame = (self.current_frame + 1) % com.common.FRAMES_IN_FLIGHT;
            return;
        }
        const image_index = res.ok;

        self.renderMainInit(vk_cmd_buff, image_index);

        try self.render_scn.render(&self.vk_ctx, vk_cmd_buff, &self.models_cache, image_index);

        try self.ui_renderer.render(&self.vk_ctx, vk_cmd_buff, imgui_ctx, self.current_frame, image_index, self.vk_ctx.vk_swap_chain.extent);

        self.renderMainFinish(vk_cmd_buff, image_index);

        try vk_cmd_buff.end(&self.vk_ctx);

        try self.submit(&vk_cmd_buff, image_index);

        _ = self.vk_ctx.vk_swap_chain.present(self.vk_ctx.vk_device, self.queue_present, self.sems_render_complete[image_index], image_index);

        self.current_frame = (self.current_frame + 1) % com.common.FRAMES_IN_FLIGHT;
    }

    /// Records a pipeline barrier transitioning the swapchain image from
    /// `color_attachment_optimal` to `present_src_khr` ready for presentation.
    fn renderMainFinish(self: *Render, vk_cmd: vk.cmd.VkCmdBuff, image_index: u32) void {
        const end_barriers = [_]vulkan.ImageMemoryBarrier2{.{
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
            .image = self.vk_ctx.vk_swap_chain.image_views[image_index].image,
        }};
        const end_dep_info = vulkan.DependencyInfo{
            .image_memory_barrier_count = end_barriers.len,
            .p_image_memory_barriers = &end_barriers,
        };
        self.vk_ctx.vk_device.device_proxy.cmdPipelineBarrier2(vk_cmd.cmd_buff_proxy.handle, &end_dep_info);
    }

    /// Records a pipeline barrier transitioning the swapchain image from
    /// `undefined` to `color_attachment_optimal` ready for rendering.
    fn renderMainInit(self: *Render, vk_cmd: vk.cmd.VkCmdBuff, image_index: u32) void {
        const init_barriers = [_]vulkan.ImageMemoryBarrier2{.{
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
            .image = self.vk_ctx.vk_swap_chain.image_views[image_index].image,
        }};
        const init_dep_info = vulkan.DependencyInfo{
            .image_memory_barrier_count = init_barriers.len,
            .p_image_memory_barriers = &init_barriers,
        };
        self.vk_ctx.vk_device.device_proxy.cmdPipelineBarrier2(vk_cmd.cmd_buff_proxy.handle, &init_dep_info);
    }

    /// Submits the command buffer to the graphics queue, waiting on the
    /// present-complete semaphore and signalling the render-complete semaphore.
    fn submit(self: *Render, vk_cmd_buff: *const vk.cmd.VkCmdBuff, image_index: u32) !void {
        const vk_fence = self.fences[self.current_frame];

        const cmd_buffer_info = vulkan.CommandBufferSubmitInfo{
            .device_mask = 0,
            .command_buffer = vk_cmd_buff.cmd_buff_proxy.handle,
        };

        const sem_wait_info = vulkan.SemaphoreSubmitInfo{
            .device_index = 0,
            .value = 0,
            .stage_mask = .{ .color_attachment_output_bit = true },
            .semaphore = self.sems_pres_complete[self.current_frame].semaphore,
        };

        const sem_signal_info = vulkan.SemaphoreSubmitInfo{
            .device_index = 0,
            .value = 0,
            .stage_mask = .{ .bottom_of_pipe_bit = true },
            .semaphore = self.sems_render_complete[image_index].semaphore,
        };

        try self.queue_graphics.submit(&self.vk_ctx, &.{cmd_buffer_info}, &.{sem_signal_info}, &.{sem_wait_info}, vk_fence);
    }
};
