const std = @import("std");

const com = @import("com");
const ui = @import("../../gui/ui.zig");
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

/// Owns the Vulkan resources needed to render one frame of ImGuiContext output.
pub const ImGuiRenderer = struct {
    /// Per-frame-in-flight host-visible vertex buffers.
    vtxBuffers: [com.common.FRAMES_IN_FLIGHT]vk.buf.VkBuffer,
    /// Per-frame-in-flight host-visible index buffers.
    idxBuffers: [com.common.FRAMES_IN_FLIGHT]vk.buf.VkBuffer,

    /// GPU-side font atlas image (R8_UNORM grayscale, 1×1 white pixel placeholder).
    atlasImage: vulkan.Image,
    atlasMemory: vulkan.DeviceMemory,
    atlasView: vulkan.ImageView,
    atlasSampler: vulkan.Sampler,

    /// Descriptor pool + layout + set for binding the font atlas sampler.
    descriptorPool: vulkan.DescriptorPool,
    descriptorSetLayout: vulkan.DescriptorSetLayout,
    descriptorSet: vulkan.DescriptorSet,

    /// 2D GUI pipeline with alpha blending and push constants.
    vkPipeline: vk.pipe.VkPipeline,

    /// Tracks atlas size and modification counter to avoid redundant uploads.
    atlasSize: u32,
    atlasModified: usize,

    /// Creates all Vulkan resources for UI rendering.
    /// cmdPool and vkQueue are needed to upload the initial atlas texture via staging buffer.
    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        vkCtx: *const vk.ctx.VkCtx,
        cmdPool: *vk.cmd.VkCmdPool,
        vkQueue: vk.queue.VkQueue,
    ) !ImGuiRenderer {

        // ---- Vertex / index buffers (per frame-in-flight) -------------------
        const vtxSize = com.common.MAX_UI_VERTICES * @sizeOf(ui.ImVertex);
        const idxSize = com.common.MAX_UI_INDICES * @sizeOf(u16);

        var vtxBuffers: [com.common.FRAMES_IN_FLIGHT]vk.buf.VkBuffer = undefined;
        var idxBuffers: [com.common.FRAMES_IN_FLIGHT]vk.buf.VkBuffer = undefined;

        for (0..com.common.FRAMES_IN_FLIGHT) |i| {
            vtxBuffers[i] = try vk.buf.VkBuffer.create(
                vkCtx,
                vtxSize,
                .{ .vertex_buffer_bit = true },
                .{ .host_visible_bit = true, .host_coherent_bit = true },
            );
            idxBuffers[i] = try vk.buf.VkBuffer.create(
                vkCtx,
                idxSize,
                .{ .index_buffer_bit = true },
                .{ .host_visible_bit = true, .host_coherent_bit = true },
            );
        }

        // ---- Sampler (linear filter, clamp-to-edge) -------------------------
        const atlasSampler = try vkCtx.vkDevice.deviceProxy.createSampler(&.{
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
        const dslBinding = vulkan.DescriptorSetLayoutBinding{
            .binding = 0,
            .descriptor_type = .combined_image_sampler,
            .descriptor_count = 1,
            .stage_flags = .{ .fragment_bit = true },
            .p_immutable_samplers = null,
        };
        const descriptorSetLayout = try vkCtx.vkDevice.deviceProxy.createDescriptorSetLayout(&.{
            .binding_count = 1,
            .p_bindings = @ptrCast(&dslBinding),
        }, null);

        // ---- Font atlas texture (1×1 white pixel placeholder) ---------------
        // A single R8_UNORM pixel at value 255 means UV (0,0) → white →
        // color * 1 = color, so solid rects render correctly without a real atlas.
        const atlasImage = try vkCtx.vkDevice.deviceProxy.createImage(&.{
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

        const imgMemReqs = vkCtx.vkDevice.deviceProxy.getImageMemoryRequirements(atlasImage);
        const atlasMemory = try vkCtx.vkDevice.deviceProxy.allocateMemory(&.{
            .allocation_size = imgMemReqs.size,
            .memory_type_index = try vkCtx.findMemoryTypeIndex(
                imgMemReqs.memory_type_bits,
                .{ .device_local_bit = true },
            ),
        }, null);
        try vkCtx.vkDevice.deviceProxy.bindImageMemory(atlasImage, atlasMemory, 0);

        const atlasView = try vkCtx.vkDevice.deviceProxy.createImageView(&.{
            .image = atlasImage,
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
        const stagingBuf = try vk.buf.VkBuffer.create(
            vkCtx,
            1,
            .{ .transfer_src_bit = true },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
        );
        defer stagingBuf.cleanup(vkCtx);

        if (try stagingBuf.map(vkCtx)) |ptr| {
            const bytes: [*]u8 = @ptrCast(ptr);
            bytes[0] = 255; // white pixel at (0,0) for solid rect rendering
            stagingBuf.unMap(vkCtx);
        }

        const uploadCmd = try vk.cmd.VkCmdBuff.create(vkCtx, cmdPool, true);
        defer uploadCmd.cleanup(vkCtx, cmdPool);
        try uploadCmd.begin(vkCtx);
        const uploadHandle = uploadCmd.cmdBuffProxy.handle;

        // Barrier: undefined → transfer_dst_optimal
        const subresRange = vulkan.ImageSubresourceRange{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        };
        const toTransfer = [_]vulkan.ImageMemoryBarrier2{.{
            .old_layout = .undefined,
            .new_layout = .transfer_dst_optimal,
            .src_stage_mask = .{ .top_of_pipe_bit = true },
            .dst_stage_mask = .{ .all_transfer_bit = true },
            .src_access_mask = .{},
            .dst_access_mask = .{ .transfer_write_bit = true },
            .src_queue_family_index = vulkan.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vulkan.QUEUE_FAMILY_IGNORED,
            .image = atlasImage,
            .subresource_range = subresRange,
        }};
        vkCtx.vkDevice.deviceProxy.cmdPipelineBarrier2(uploadHandle, &.{
            .image_memory_barrier_count = toTransfer.len,
            .p_image_memory_barriers = &toTransfer,
        });

        // Copy staging buffer → atlas image
        const copyRegion = [_]vulkan.BufferImageCopy{.{
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
        vkCtx.vkDevice.deviceProxy.cmdCopyBufferToImage(
            uploadHandle,
            stagingBuf.buffer,
            atlasImage,
            .transfer_dst_optimal,
            copyRegion.len,
            &copyRegion,
        );

        // Barrier: transfer_dst_optimal → shader_read_only_optimal
        const toShaderRead = [_]vulkan.ImageMemoryBarrier2{.{
            .old_layout = .transfer_dst_optimal,
            .new_layout = .shader_read_only_optimal,
            .src_stage_mask = .{ .all_transfer_bit = true },
            .dst_stage_mask = .{ .fragment_shader_bit = true },
            .src_access_mask = .{ .transfer_write_bit = true },
            .dst_access_mask = .{ .shader_read_bit = true },
            .src_queue_family_index = vulkan.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vulkan.QUEUE_FAMILY_IGNORED,
            .image = atlasImage,
            .subresource_range = subresRange,
        }};
        vkCtx.vkDevice.deviceProxy.cmdPipelineBarrier2(uploadHandle, &.{
            .image_memory_barrier_count = toShaderRead.len,
            .p_image_memory_barriers = &toShaderRead,
        });

        try uploadCmd.end(vkCtx);
        try uploadCmd.submitAndWait(vkCtx, vkQueue);

        // ---- Descriptor pool + set ------------------------------------------
        const poolSize = vulkan.DescriptorPoolSize{
            .type = .combined_image_sampler,
            .descriptor_count = 1,
        };
        const descriptorPool = try vkCtx.vkDevice.deviceProxy.createDescriptorPool(&.{
            .max_sets = 1,
            .pool_size_count = 1,
            .p_pool_sizes = @ptrCast(&poolSize),
        }, null);

        var descriptorSet: vulkan.DescriptorSet = undefined;
        try vkCtx.vkDevice.deviceProxy.allocateDescriptorSets(&.{
            .descriptor_pool = descriptorPool,
            .descriptor_set_count = 1,
            .p_set_layouts = @ptrCast(&descriptorSetLayout),
        }, @ptrCast(&descriptorSet));

        const imageInfo = vulkan.DescriptorImageInfo{
            .sampler = atlasSampler,
            .image_view = atlasView,
            .image_layout = .shader_read_only_optimal,
        };
        const writeDescSet = vulkan.WriteDescriptorSet{
            .dst_set = descriptorSet,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .p_image_info = @ptrCast(&imageInfo),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        };
        vkCtx.vkDevice.deviceProxy.updateDescriptorSets(1, @ptrCast(&writeDescSet), 0, null);

        // ---- Pipeline -------------------------------------------------------
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const arenaAlloc = arena.allocator();

        const vertCode align(@alignOf(u32)) = try com.utils.loadFile(arenaAlloc, io, "res/shaders/gui_vtx.glsl.spv");
        const vert = try vkCtx.vkDevice.deviceProxy.createShaderModule(&.{
            .code_size = vertCode.len,
            .p_code = @ptrCast(@alignCast(vertCode)),
        }, null);
        defer vkCtx.vkDevice.deviceProxy.destroyShaderModule(vert, null);

        const fragCode align(@alignOf(u32)) = try com.utils.loadFile(arenaAlloc, io, "res/shaders/gui_frg.glsl.spv");
        const frag = try vkCtx.vkDevice.deviceProxy.createShaderModule(&.{
            .code_size = fragCode.len,
            .p_code = @ptrCast(@alignCast(fragCode)),
        }, null);
        defer vkCtx.vkDevice.deviceProxy.destroyShaderModule(frag, null);

        const modulesInfo = try allocator.alloc(vk.pipe.ShaderModuleInfo, 2);
        defer allocator.free(modulesInfo);
        modulesInfo[0] = .{ .module = vert, .stage = .{ .vertex_bit = true } };
        modulesInfo[1] = .{ .module = frag, .stage = .{ .fragment_bit = true } };

        const pipelineCreateInfo = vk.pipe.VkPipelineCreateInfo{
            .colorFormat = vkCtx.vkSwapChain.surfaceFormat.format,
            .modulesInfo = modulesInfo,
            .useBlend = true,
            .vtxBuffDesc = .{
                .binding_description = binding_description,
                .attribute_description = @constCast(&attribute_descriptions)[0..],
            },
            .pushConstantRanges = &.{.{
                .stage_flags = .{ .vertex_bit = true },
                .offset = 0,
                .size = @sizeOf(GuiPushConstants),
            }},
            .descriptorSetLayouts = &.{descriptorSetLayout},
        };
        const vkPipeline = try vk.pipe.VkPipeline.create(allocator, vkCtx, &pipelineCreateInfo);

        log.debug("ImGuiRenderer created", .{});

        return .{
            .vtxBuffers = vtxBuffers,
            .idxBuffers = idxBuffers,
            .atlasImage = atlasImage,
            .atlasMemory = atlasMemory,
            .atlasView = atlasView,
            .atlasSampler = atlasSampler,
            .descriptorPool = descriptorPool,
            .descriptorSetLayout = descriptorSetLayout,
            .descriptorSet = descriptorSet,
            .vkPipeline = vkPipeline,
            .atlasSize = 1,
            .atlasModified = 0,
        };
    }

    /// Records UI draw commands into vkCmd for the current frame.
    pub fn render(
        self: *ImGuiRenderer,
        vkCtx: *const vk.ctx.VkCtx,
        vkCmd: vk.cmd.VkCmdBuff,
        imgui: *ui.ImGuiContext,
        frameIndex: u8,
        imageIndex: u32,
        extent: vulkan.Extent2D,
    ) !void {
        if (imgui.indices.items.len == 0) return;

        // ---- Upload vertex + index data to current frame's buffers ----------
        const vtxBuf = &self.vtxBuffers[frameIndex];
        const idxBuf = &self.idxBuffers[frameIndex];

        if (try vtxBuf.map(vkCtx)) |ptr| {
            const dst: [*]ui.ImVertex = @ptrCast(@alignCast(ptr));
            @memcpy(dst[0..imgui.vertices.items.len], imgui.vertices.items);
            vtxBuf.unMap(vkCtx);
        }
        if (try idxBuf.map(vkCtx)) |ptr| {
            const dst: [*]u16 = @ptrCast(@alignCast(ptr));
            @memcpy(dst[0..imgui.indices.items.len], imgui.indices.items);
            idxBuf.unMap(vkCtx);
        }

        // ---- Begin dynamic rendering (load_op=load composites over scene) ---
        const cmdHandle = vkCmd.cmdBuffProxy.handle;
        const device = vkCtx.vkDevice.deviceProxy;

        const renderAttInfo = vulkan.RenderingAttachmentInfo{
            .image_view = vkCtx.vkSwapChain.imageViews[imageIndex].view,
            .image_layout = .attachment_optimal_khr,
            .load_op = .load,
            .store_op = .store,
            .clear_value = .{ .color = .{ .float_32 = .{ 0, 0, 0, 0 } } },
            .resolve_mode = .{},
            .resolve_image_layout = .attachment_optimal_khr,
        };
        const renderInfo = vulkan.RenderingInfo{
            .render_area = .{ .extent = extent, .offset = .{ .x = 0, .y = 0 } },
            .layer_count = 1,
            .color_attachment_count = 1,
            .p_color_attachments = &[_]vulkan.RenderingAttachmentInfo{renderAttInfo},
            .view_mask = 0,
        };
        device.cmdBeginRendering(cmdHandle, @ptrCast(&renderInfo));

        // ---- Bind pipeline --------------------------------------------------
        device.cmdBindPipeline(cmdHandle, .graphics, self.vkPipeline.pipeline);

        // ---- Push scale constants -------------------------------------------
        const pushConsts = GuiPushConstants{
            .scale = .{
                2.0 / @as(f32, @floatFromInt(extent.width)),
                2.0 / @as(f32, @floatFromInt(extent.height)),
            },
        };
        device.cmdPushConstants(
            cmdHandle,
            self.vkPipeline.pipelineLayout,
            .{ .vertex_bit = true },
            0,
            @sizeOf(GuiPushConstants),
            &pushConsts,
        );

        // ---- Bind vertex + index buffers ------------------------------------
        const vtxOffset = [_]vulkan.DeviceSize{0};
        device.cmdBindVertexBuffers(cmdHandle, 0, 1, @ptrCast(&vtxBuf.buffer), &vtxOffset);
        device.cmdBindIndexBuffer(cmdHandle, idxBuf.buffer, 0, .uint16);

        // ---- Viewport -------------------------------------------------------
        const viewport = [_]vulkan.Viewport{.{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(extent.width),
            .height = @floatFromInt(extent.height),
            .min_depth = 0,
            .max_depth = 1,
        }};
        device.cmdSetViewport(cmdHandle, 0, 1, &viewport);

        // ---- Draw commands (one per ImDrawCmd, each with its own scissor) ---
        var vtxOffset_acc: i32 = 0;
        var idxOffset_acc: u32 = 0;

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
            device.cmdSetScissor(cmdHandle, 0, 1, &scissor);

            device.cmdBindDescriptorSets(
                cmdHandle,
                .graphics,
                self.vkPipeline.pipelineLayout,
                0,
                1,
                @ptrCast(&self.descriptorSet),
                0,
                null,
            );

            device.cmdDrawIndexed(cmdHandle, cmd_entry.elem_count, 1, idxOffset_acc, vtxOffset_acc, 0);

            idxOffset_acc += cmd_entry.elem_count;
            vtxOffset_acc += 0; // TODO: track per-cmd vertex offset when split across cmds
        }

        device.cmdEndRendering(cmdHandle);
    }

    /// Destroys all Vulkan resources owned by this renderer.
    pub fn cleanup(self: *ImGuiRenderer, vkCtx: *const vk.ctx.VkCtx) void {
        self.vkPipeline.cleanup(vkCtx);

        for (0..com.common.FRAMES_IN_FLIGHT) |i| {
            self.vtxBuffers[i].cleanup(vkCtx);
            self.idxBuffers[i].cleanup(vkCtx);
        }

        vkCtx.vkDevice.deviceProxy.destroyDescriptorPool(self.descriptorPool, null);
        vkCtx.vkDevice.deviceProxy.destroyDescriptorSetLayout(self.descriptorSetLayout, null);
        vkCtx.vkDevice.deviceProxy.destroyImageView(self.atlasView, null);
        vkCtx.vkDevice.deviceProxy.destroyImage(self.atlasImage, null);
        vkCtx.vkDevice.deviceProxy.freeMemory(self.atlasMemory, null);
        vkCtx.vkDevice.deviceProxy.destroySampler(self.atlasSampler, null);

        log.debug("ImGuiRenderer destroyed", .{});
    }
};
