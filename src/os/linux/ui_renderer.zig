const std = @import("std");

const com = @import("com");
const ui = @import("../../ui/ui.zig");
const vk = @import("vk");
const vulkan = @import("vulkan");

const log = std.log.scoped(.uiRenderer);

// ImVertex layout for the GUI pipeline:
//   location 0 — position [2]f32  offset  0  r32g32_sfloat
//   location 1 — uv       [2]f32  offset  8  r32g32_sfloat
//   location 2 — color    u32     offset 16  r8g8b8a8_unorm
//   stride 20 bytes
const binding_description = vulkan.VertexInputBindingDescription{
    .binding = 0,
    .stride = @sizeOf(ui.ImVertex),
    .input_rate = .vertex,
};

const attribute_descriptions = [_]vulkan.VertexInputAttributeDescription{
    .{ .binding = 0, .location = 0, .format = .r32g32_sfloat, .offset = @offsetOf(ui.ImVertex, "position") },
    .{ .binding = 0, .location = 1, .format = .r32g32_sfloat, .offset = @offsetOf(ui.ImVertex, "uv") },
    .{ .binding = 0, .location = 2, .format = .r8g8b8a8_unorm, .offset = @offsetOf(ui.ImVertex, "color") },
};

/// Push constants for the GUI vertex shader: scale = (2/width, -2/height)
const GuiPushConstants = extern struct {
    scale: [2]f32,
};

/// Owns the Vulkan resources needed to render one frame of ImGui output.
pub const ImGuiRenderer = struct {
    /// Per-frame-in-flight host-visible vertex buffers.
    vtx_buffers: [com.common.FRAMES_IN_FLIGHT]vk.buf.VkBuffer,
    /// Per-frame-in-flight host-visible index buffers.
    idx_buffers: [com.common.FRAMES_IN_FLIGHT]vk.buf.VkBuffer,

    /// GPU-side font atlas image (R8_UNORM grayscale, 1×1 white pixel placeholder).
    atlas_image: vulkan.Image,
    atlas_memory: vulkan.DeviceMemory,
    atlas_view: vulkan.ImageView,
    atlas_sampler: vulkan.Sampler,

    /// Descriptor pool + layout + set for binding the font atlas sampler.
    descriptor_pool: vulkan.DescriptorPool,
    descriptor_set_layout: vulkan.DescriptorSetLayout,
    descriptor_set: vulkan.DescriptorSet,

    /// 2D GUI pipeline with alpha blending and push constants.
    vk_pipeline: vk.pipe.VkPipeline,

    /// Tracks atlas size and modification counter to avoid redundant uploads.
    atlas_size: u32,
    atlas_modified: usize,

    /// Creates all Vulkan resources for UI rendering.
    /// cmd_pool and vk_queue are needed to upload the initial atlas texture via staging buffer.
    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        vk_ctx: *const vk.ctx.VkCtx,
        cmd_pool: *vk.cmd.VkCmdPool,
        vk_queue: vk.queue.VkQueue,
    ) !ImGuiRenderer {

        // ---- Vertex / index buffers (per frame-in-flight) -------------------
        const vtx_size = com.common.MAX_UI_VERTICES * @sizeOf(ui.ImVertex);
        const idx_size = com.common.MAX_UI_INDICES * @sizeOf(u16);

        var vtx_buffers: [com.common.FRAMES_IN_FLIGHT]vk.buf.VkBuffer = undefined;
        var idx_buffers: [com.common.FRAMES_IN_FLIGHT]vk.buf.VkBuffer = undefined;

        for (0..com.common.FRAMES_IN_FLIGHT) |i| {
            vtx_buffers[i] = try vk.buf.VkBuffer.create(
                vk_ctx,
                vtx_size,
                .{ .vertex_buffer_bit = true },
                .{ .host_visible_bit = true, .host_coherent_bit = true },
            );
            idx_buffers[i] = try vk.buf.VkBuffer.create(
                vk_ctx,
                idx_size,
                .{ .index_buffer_bit = true },
                .{ .host_visible_bit = true, .host_coherent_bit = true },
            );
        }

        // ---- Sampler (linear filter, clamp-to-edge) -------------------------
        const atlas_sampler = try vk_ctx.vk_device.device_proxy.createSampler(&.{
            .mag_filter = .linear,
            .min_filter = .linear,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
            .anisotropy_enable = vulkan.Bool32.false,
            .max_anisotropy = 1.0,
            .border_color = .int_opaque_black,
            .unnormalized_coordinates = vulkan.Bool32.false,
            .compare_enable = vulkan.Bool32.false,
            .compare_op = .always,
            .mipmap_mode = .linear,
            .mip_lod_bias = 0,
            .min_lod = 0,
            .max_lod = 0,
        }, null);

        // ---- Descriptor set layout (binding 0 = combined image sampler) -----
        const dsl_binding = vulkan.DescriptorSetLayoutBinding{
            .binding = 0,
            .descriptor_type = .combined_image_sampler,
            .descriptor_count = 1,
            .stage_flags = .{ .fragment_bit = true },
            .p_immutable_samplers = null,
        };
        const descriptor_set_layout = try vk_ctx.vk_device.device_proxy.createDescriptorSetLayout(&.{
            .binding_count = 1,
            .p_bindings = @ptrCast(&dsl_binding),
        }, null);

        // ---- Font atlas texture (1×1 white pixel placeholder) ---------------
        // A single R8_UNORM pixel at value 255 means UV (0,0) → white →
        // color * 1 = color, so solid rects render correctly without a real atlas.
        const atlas_image = try vk_ctx.vk_device.device_proxy.createImage(&.{
            .image_type = .@"2d",
            .format = .r8_unorm,
            .extent = .{ .width = 1, .height = 1, .depth = 1 },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .{ .@"1_bit" = true },
            .tiling = .optimal,
            .usage = .{ .sampled_bit = true, .transfer_dst_bit = true },
            .sharing_mode = .exclusive,
            .initial_layout = .undefined,
        }, null);

        const img_mem_reqs = vk_ctx.vk_device.device_proxy.getImageMemoryRequirements(atlas_image);
        const atlas_memory = try vk_ctx.vk_device.device_proxy.allocateMemory(&.{
            .allocation_size = img_mem_reqs.size,
            .memory_type_index = try vk_ctx.findMemoryTypeIndex(
                img_mem_reqs.memory_type_bits,
                .{ .device_local_bit = true },
            ),
        }, null);
        try vk_ctx.vk_device.device_proxy.bindImageMemory(atlas_image, atlas_memory, 0);

        const atlas_view = try vk_ctx.vk_device.device_proxy.createImageView(&.{
            .image = atlas_image,
            .view_type = .@"2d",
            .format = .r8_unorm,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null);

        // Upload white pixel via staging buffer + one-shot command buffer
        const staging_buf = try vk.buf.VkBuffer.create(
            vk_ctx,
            1,
            .{ .transfer_src_bit = true },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
        );
        defer staging_buf.cleanup(vk_ctx);

        if (try staging_buf.map(vk_ctx)) |ptr| {
            const bytes: [*]u8 = @ptrCast(ptr);
            bytes[0] = 255; // white pixel at (0,0) for solid rect rendering
            staging_buf.unMap(vk_ctx);
        }

        const upload_cmd = try vk.cmd.VkCmdBuff.create(vk_ctx, cmd_pool, true);
        defer upload_cmd.cleanup(vk_ctx, cmd_pool);
        try upload_cmd.begin(vk_ctx);
        const upload_handle = upload_cmd.cmd_buff_proxy.handle;

        // Barrier: undefined → transfer_dst_optimal
        const subres_range = vulkan.ImageSubresourceRange{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        };
        const to_transfer = [_]vulkan.ImageMemoryBarrier2{.{
            .old_layout = .undefined,
            .new_layout = .transfer_dst_optimal,
            .src_stage_mask = .{ .top_of_pipe_bit = true },
            .dst_stage_mask = .{ .all_transfer_bit = true },
            .src_access_mask = .{},
            .dst_access_mask = .{ .transfer_write_bit = true },
            .src_queue_family_index = vulkan.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vulkan.QUEUE_FAMILY_IGNORED,
            .image = atlas_image,
            .subresource_range = subres_range,
        }};
        vk_ctx.vk_device.device_proxy.cmdPipelineBarrier2(upload_handle, &.{
            .image_memory_barrier_count = to_transfer.len,
            .p_image_memory_barriers = &to_transfer,
        });

        // Copy staging buffer → atlas image
        const copy_region = [_]vulkan.BufferImageCopy{.{
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{
                .aspect_mask = .{ .color_bit = true },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = .{ .width = 1, .height = 1, .depth = 1 },
        }};
        vk_ctx.vk_device.device_proxy.cmdCopyBufferToImage(
            upload_handle,
            staging_buf.buffer,
            atlas_image,
            .transfer_dst_optimal,
            copy_region.len,
            &copy_region,
        );

        // Barrier: transfer_dst_optimal → shader_read_only_optimal
        const to_shader_read = [_]vulkan.ImageMemoryBarrier2{.{
            .old_layout = .transfer_dst_optimal,
            .new_layout = .shader_read_only_optimal,
            .src_stage_mask = .{ .all_transfer_bit = true },
            .dst_stage_mask = .{ .fragment_shader_bit = true },
            .src_access_mask = .{ .transfer_write_bit = true },
            .dst_access_mask = .{ .shader_read_bit = true },
            .src_queue_family_index = vulkan.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vulkan.QUEUE_FAMILY_IGNORED,
            .image = atlas_image,
            .subresource_range = subres_range,
        }};
        vk_ctx.vk_device.device_proxy.cmdPipelineBarrier2(upload_handle, &.{
            .image_memory_barrier_count = to_shader_read.len,
            .p_image_memory_barriers = &to_shader_read,
        });

        try upload_cmd.end(vk_ctx);
        try upload_cmd.submitAndWait(vk_ctx, vk_queue);

        // ---- Descriptor pool + set ------------------------------------------
        const pool_size = vulkan.DescriptorPoolSize{
            .type = .combined_image_sampler,
            .descriptor_count = 1,
        };
        const descriptor_pool = try vk_ctx.vk_device.device_proxy.createDescriptorPool(&.{
            .max_sets = 1,
            .pool_size_count = 1,
            .p_pool_sizes = @ptrCast(&pool_size),
        }, null);

        var descriptor_set: vulkan.DescriptorSet = undefined;
        try vk_ctx.vk_device.device_proxy.allocateDescriptorSets(&.{
            .descriptor_pool = descriptor_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = @ptrCast(&descriptor_set_layout),
        }, @ptrCast(&descriptor_set));

        const image_info = vulkan.DescriptorImageInfo{
            .sampler = atlas_sampler,
            .image_view = atlas_view,
            .image_layout = .shader_read_only_optimal,
        };
        const write_desc_set = vulkan.WriteDescriptorSet{
            .dst_set = descriptor_set,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .p_image_info = @ptrCast(&image_info),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        };
        vk_ctx.vk_device.device_proxy.updateDescriptorSets(1, @ptrCast(&write_desc_set), 0, null);

        // ---- Pipeline -------------------------------------------------------
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const vert_code = try std.Io.Dir.cwd().readFileAllocOptions(io, "res/shaders/gui_vtx.glsl.spv", arena_alloc, .unlimited, .of(u32), null);
        const vert = try vk_ctx.vk_device.device_proxy.createShaderModule(&.{
            .code_size = vert_code.len,
            .p_code = @ptrCast(vert_code),
        }, null);
        defer vk_ctx.vk_device.device_proxy.destroyShaderModule(vert, null);

        const frag_code = try std.Io.Dir.cwd().readFileAllocOptions(io, "res/shaders/gui_frg.glsl.spv", arena_alloc, .unlimited, .of(u32), null);
        const frag = try vk_ctx.vk_device.device_proxy.createShaderModule(&.{
            .code_size = frag_code.len,
            .p_code = @ptrCast(frag_code),
        }, null);
        defer vk_ctx.vk_device.device_proxy.destroyShaderModule(frag, null);

        const modules_info = try allocator.alloc(vk.pipe.ShaderModuleInfo, 2);
        defer allocator.free(modules_info);
        modules_info[0] = .{ .module = vert, .stage = .{ .vertex_bit = true } };
        modules_info[1] = .{ .module = frag, .stage = .{ .fragment_bit = true } };

        const pipeline_create_info = vk.pipe.VkPipelineCreateInfo{
            .color_format = vk_ctx.vk_swap_chain.surface_format.format,
            .modules_info = modules_info,
            .use_blend = true,
            .vtx_buff_desc = .{
                .binding_description = binding_description,
                .attribute_description = @constCast(&attribute_descriptions)[0..],
            },
            .push_constant_ranges = &.{.{
                .stage_flags = .{ .vertex_bit = true },
                .offset = 0,
                .size = @sizeOf(GuiPushConstants),
            }},
            .descriptor_set_layouts = &.{descriptor_set_layout},
        };
        const vk_pipeline = try vk.pipe.VkPipeline.create(allocator, vk_ctx, &pipeline_create_info);

        log.debug("ImGuiRenderer created", .{});

        return .{
            .vtx_buffers = vtx_buffers,
            .idx_buffers = idx_buffers,
            .atlas_image = atlas_image,
            .atlas_memory = atlas_memory,
            .atlas_view = atlas_view,
            .atlas_sampler = atlas_sampler,
            .descriptor_pool = descriptor_pool,
            .descriptor_set_layout = descriptor_set_layout,
            .descriptor_set = descriptor_set,
            .vk_pipeline = vk_pipeline,
            .atlas_size = 1,
            .atlas_modified = 0,
        };
    }

    /// Records UI draw commands into vk_cmd for the current frame.
    pub fn render(
        self: *ImGuiRenderer,
        vk_ctx: *const vk.ctx.VkCtx,
        vk_cmd: vk.cmd.VkCmdBuff,
        imgui: *ui.ImGui,
        frame_index: u8,
        image_index: u32,
        extent: vulkan.Extent2D,
    ) !void {
        if (imgui.indices.items.len == 0) return;

        // ---- Upload vertex + index data to current frame's buffers ----------
        const vtx_buf = &self.vtx_buffers[frame_index];
        const idx_buf = &self.idx_buffers[frame_index];

        if (try vtx_buf.map(vk_ctx)) |ptr| {
            const dst: [*]ui.ImVertex = @ptrCast(@alignCast(ptr));
            @memcpy(dst[0..imgui.vertices.items.len], imgui.vertices.items);
            vtx_buf.unMap(vk_ctx);
        }
        if (try idx_buf.map(vk_ctx)) |ptr| {
            const dst: [*]u16 = @ptrCast(@alignCast(ptr));
            @memcpy(dst[0..imgui.indices.items.len], imgui.indices.items);
            idx_buf.unMap(vk_ctx);
        }

        // ---- Begin dynamic rendering (load_op=load composites over scene) ---
        const cmd_handle = vk_cmd.cmd_buff_proxy.handle;
        const device = vk_ctx.vk_device.device_proxy;

        const render_att_info = vulkan.RenderingAttachmentInfo{
            .image_view = vk_ctx.vk_swap_chain.image_views[image_index].view,
            .image_layout = .attachment_optimal_khr,
            .load_op = .load,
            .store_op = .store,
            .clear_value = .{ .color = .{ .float_32 = .{ 0, 0, 0, 0 } } },
            .resolve_mode = .{},
            .resolve_image_layout = .attachment_optimal_khr,
        };
        const render_info = vulkan.RenderingInfo{
            .render_area = .{ .extent = extent, .offset = .{ .x = 0, .y = 0 } },
            .layer_count = 1,
            .color_attachment_count = 1,
            .p_color_attachments = &[_]vulkan.RenderingAttachmentInfo{render_att_info},
            .view_mask = 0,
        };
        device.cmdBeginRendering(cmd_handle, @ptrCast(&render_info));

        // ---- Bind pipeline --------------------------------------------------
        device.cmdBindPipeline(cmd_handle, .graphics, self.vk_pipeline.pipeline);

        // ---- Push scale constants -------------------------------------------
        const push_consts = GuiPushConstants{
            .scale = .{
                2.0 / @as(f32, @floatFromInt(extent.width)),
                2.0 / @as(f32, @floatFromInt(extent.height)),
            },
        };
        device.cmdPushConstants(
            cmd_handle,
            self.vk_pipeline.pipeline_layout,
            .{ .vertex_bit = true },
            0,
            @sizeOf(GuiPushConstants),
            &push_consts,
        );

        // ---- Bind vertex + index buffers ------------------------------------
        const vtx_offset = [_]vulkan.DeviceSize{0};
        device.cmdBindVertexBuffers(cmd_handle, 0, 1, @ptrCast(&vtx_buf.buffer), &vtx_offset);
        device.cmdBindIndexBuffer(cmd_handle, idx_buf.buffer, 0, .uint16);

        // ---- Viewport -------------------------------------------------------
        const viewport = [_]vulkan.Viewport{.{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(extent.width),
            .height = @floatFromInt(extent.height),
            .min_depth = 0,
            .max_depth = 1,
        }};
        device.cmdSetViewport(cmd_handle, 0, 1, &viewport);

        // ---- Draw commands (one per ImDrawCmd, each with its own scissor) ---
        var vtx_offset_acc: i32 = 0;
        var idx_offset_acc: u32 = 0;

        for (imgui.draw_cmds.items) |cmd_entry| {
            const scissor = [_]vulkan.Rect2D{.{
                .offset = .{
                    .x = @intFromFloat(cmd_entry.clip_rect[0]),
                    .y = @intFromFloat(cmd_entry.clip_rect[1]),
                },
                .extent = .{
                    .width = @intFromFloat(cmd_entry.clip_rect[2]),
                    .height = @intFromFloat(cmd_entry.clip_rect[3]),
                },
            }};
            device.cmdSetScissor(cmd_handle, 0, 1, &scissor);

            device.cmdBindDescriptorSets(
                cmd_handle,
                .graphics,
                self.vk_pipeline.pipeline_layout,
                0,
                1,
                @ptrCast(&self.descriptor_set),
                0,
                null,
            );

            device.cmdDrawIndexed(cmd_handle, cmd_entry.elem_count, 1, idx_offset_acc, vtx_offset_acc, 0);

            idx_offset_acc += cmd_entry.elem_count;
            vtx_offset_acc += 0; // TODO: track per-cmd vertex offset when split across cmds
        }

        device.cmdEndRendering(cmd_handle);
    }

    /// Destroys all Vulkan resources owned by this renderer.
    pub fn cleanup(self: *ImGuiRenderer, vk_ctx: *const vk.ctx.VkCtx) void {
        self.vk_pipeline.cleanup(vk_ctx);

        for (0..com.common.FRAMES_IN_FLIGHT) |i| {
            self.vtx_buffers[i].cleanup(vk_ctx);
            self.idx_buffers[i].cleanup(vk_ctx);
        }

        vk_ctx.vk_device.device_proxy.destroyDescriptorPool(self.descriptor_pool, null);
        vk_ctx.vk_device.device_proxy.destroyDescriptorSetLayout(self.descriptor_set_layout, null);
        vk_ctx.vk_device.device_proxy.destroyImageView(self.atlas_view, null);
        vk_ctx.vk_device.device_proxy.destroyImage(self.atlas_image, null);
        vk_ctx.vk_device.device_proxy.freeMemory(self.atlas_memory, null);
        vk_ctx.vk_device.device_proxy.destroySampler(self.atlas_sampler, null);

        log.debug("ImGuiRenderer destroyed", .{});
    }
};
