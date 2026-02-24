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

    /// GPU-side font atlas image (R8_UNORM grayscale).
    atlasImage: vulkan.Image,
    atlasMemory: vulkan.DeviceMemory,
    atlasView: vulkan.ImageView,
    atlasSampler: vulkan.Sampler,

    /// Descriptor pool + layout + set for binding the font atlas sampler.
    descriptorPool: vulkan.DescriptorPool,
    descriptorSetLayout: vulkan.DescriptorSetLayout,
    descriptorSet: vulkan.DescriptorSet,

    /// 2D GUI pipeline with alpha blending and push constants.
    /// NOTE: VkPipeline.create will need push constant + descriptor set layout
    /// support added before this can be created — see TODO in create().
    vkPipeline: vk.pipe.VkPipeline,

    /// Tracks atlas size and modification counter to avoid redundant uploads.
    atlasSize: u32,
    atlasModified: usize,

    /// Creates all Vulkan resources for UI rendering.
    pub fn create(allocator: std.mem.Allocator, io: std.Io, vkCtx: *const vk.ctx.VkCtx) !ImGuiRenderer {

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

        // ---- Font atlas texture ----------------------------------------------
        // TODO: create VkImage (r8_unorm, transfer_dst + sampled),
        //       allocate + bind device memory, create VkImageView,
        //       transition layout, upload initial atlas pixels via staging buffer.
        //       Seed pixel [0] = 255 (white) before upload for solid rect rendering.
        // See: modelsCache.zig staging buffer pattern.
        const atlasImage: vulkan.Image = .null_handle;
        const atlasMemory: vulkan.DeviceMemory = .null_handle;
        const atlasView: vulkan.ImageView = .null_handle;

        // ---- Sampler --------------------------------------------------------
        // TODO: createSampler (linear filter, clamp_to_edge)
        const atlasSampler: vulkan.Sampler = .null_handle;

        // ---- Descriptor set layout (binding 0 = combined image sampler) -----
        // TODO: createDescriptorSetLayout with one VkDescriptorSetLayoutBinding:
        //   binding=0, type=combined_image_sampler, stage=fragment
        const descriptorSetLayout: vulkan.DescriptorSetLayout = .null_handle;

        // ---- Descriptor pool + set ------------------------------------------
        // TODO: createDescriptorPool (1 set, 1 combined_image_sampler)
        // TODO: allocateDescriptorSets
        // TODO: updateDescriptorSets to bind atlasSampler + atlasView
        const descriptorPool: vulkan.DescriptorPool = .null_handle;
        const descriptorSet: vulkan.DescriptorSet = .null_handle;

        // ---- Pipeline -------------------------------------------------------
        // TODO: VkPipeline.create needs two additions before this works:
        //   1. Push constant range: stage=vertex, offset=0, size=@sizeOf(GuiPushConstants)
        //   2. Descriptor set layout passed into pipelineLayout creation
        // For now, load shaders and call create with useBlend=true.
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
            .useBlend = true, // alpha blending for UI overlay
            .vtxBuffDesc = .{
                .binding_description = binding_description,
                .attribute_description = @constCast(&attribute_descriptions)[0..],
            },
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
            .atlasSize = 0,
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
        extent: vulkan.Extent2D,
    ) !void {
        if (imgui.indices.items.len == 0) return;

        // ---- Upload vertex + index data to current frame's buffers ----------
        const vtxBuf = &self.vtxBuffers[frameIndex];
        const idxBuf = &self.idxBuffers[frameIndex];

        const vtxData = try vtxBuf.map(vkCtx);
        const idxData = try idxBuf.map(vkCtx);

        if (vtxData) |ptr| {
            const dst: [*]ui.ImVertex = @ptrCast(@alignCast(ptr));
            @memcpy(dst, imgui.vertices.items);
        }
        if (idxData) |ptr| {
            const dst: [*]u16 = @ptrCast(@alignCast(ptr));
            @memcpy(dst, imgui.indices.items);
        }

        vtxBuf.unMap(vkCtx);
        idxBuf.unMap(vkCtx);

        // ---- Bind pipeline --------------------------------------------------
        const cmdHandle = vkCmd.cmdBuffProxy.handle;
        const device = vkCtx.vkDevice.deviceProxy;

        device.cmdBindPipeline(cmdHandle, .graphics, self.vkPipeline.pipeline);

        // ---- Push scale constants -------------------------------------------
        const pushConsts = GuiPushConstants{
            .scale = .{
                2.0 / @as(f32, @floatFromInt(extent.width)),
                -2.0 / @as(f32, @floatFromInt(extent.height)),
            },
        };
        // TODO: cmdPushConstants once pipelineLayout has push constant range declared.
        _ = pushConsts;

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

            // TODO: bind descriptorSet once atlas texture + descriptor set are created.

            device.cmdDrawIndexed(cmdHandle, cmd_entry.elem_count, 1, idxOffset_acc, vtxOffset_acc, 0);

            idxOffset_acc += cmd_entry.elem_count;
            vtxOffset_acc += 0; // TODO: track per-cmd vertex offset when split across cmds
        }
    }

    /// Destroys all Vulkan resources owned by this renderer.
    pub fn cleanup(self: *ImGuiRenderer, vkCtx: *const vk.ctx.VkCtx) void {
        self.vkPipeline.cleanup(vkCtx);

        for (0..com.common.FRAMES_IN_FLIGHT) |i| {
            self.vtxBuffers[i].cleanup(vkCtx);
            self.idxBuffers[i].cleanup(vkCtx);
        }

        // TODO: destroy atlasImage, atlasMemory, atlasView, atlasSampler,
        //       descriptorPool, descriptorSetLayout once they are created.
        log.debug("ImGuiRenderer destroyed", .{});
    }
};
