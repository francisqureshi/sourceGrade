const std = @import("std");

const com = @import("com");
const mcach = @import("modelsCache.zig");
const vk = @import("vk");
const vulkan = @import("vulkan");

/// Vertex layout for scene geometry: a single XYZ position attribute.
const VtxBuffDesc = struct {
    const binding_description = vulkan.VertexInputBindingDescription{
        .binding = 0,
        .stride = @sizeOf(VtxBuffDesc),
        .input_rate = .vertex,
    };

    const attribute_description = [_]vulkan.VertexInputAttributeDescription{
        .{
            .binding = 0,
            .location = 0,
            .format = .r32g32b32_sfloat,
            .offset = @offsetOf(VtxBuffDesc, "pos"),
        },
    };

    pos: [3]f32,
};

/// Owns the graphics pipeline for 3D scene rendering.
pub const RenderScn = struct {
    vk_pipeline: vk.pipe.VkPipeline,

    /// Destroys the graphics pipeline.
    pub fn cleanup(self: *RenderScn, allocator: std.mem.Allocator, vk_ctx: *const vk.ctx.VkCtx) void {
        _ = allocator;
        self.vk_pipeline.cleanup(vk_ctx);
    }

    /// Loads SPIR-V vertex and fragment shaders from disk and creates the
    /// graphics pipeline for scene rendering.
    pub fn create(allocator: std.mem.Allocator, io: std.Io, vk_ctx: *const vk.ctx.VkCtx) !RenderScn {
        // Shader modules
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const vert_code = try std.Io.Dir.cwd().readFileAllocOptions(io, "res/shaders/scn_vtx.glsl.spv", arena.allocator(), .unlimited, .of(u32), null);
        const vert = try vk_ctx.vk_device.device_proxy.createShaderModule(&.{
            .code_size = vert_code.len,
            .p_code = @ptrCast(vert_code),
        }, null);
        defer vk_ctx.vk_device.device_proxy.destroyShaderModule(vert, null);

        const frag_code = try std.Io.Dir.cwd().readFileAllocOptions(io, "res/shaders/scn_frg.glsl.spv", arena.allocator(), .unlimited, .of(u32), null);
        const frag = try vk_ctx.vk_device.device_proxy.createShaderModule(&.{
            .code_size = frag_code.len,
            .p_code = @ptrCast(frag_code),
        }, null);
        defer vk_ctx.vk_device.device_proxy.destroyShaderModule(frag, null);

        const modules_info = try allocator.alloc(vk.pipe.ShaderModuleInfo, 2);
        modules_info[0] = .{ .module = vert, .stage = .{ .vertex_bit = true } };
        modules_info[1] = .{ .module = frag, .stage = .{ .fragment_bit = true } };
        defer allocator.free(modules_info);

        // Pipeline
        const vk_pipelineCreateInfo = vk.pipe.VkPipelineCreateInfo{
            .color_format = vk_ctx.vk_swap_chain.surface_format.format,
            .modules_info = modules_info,
            .use_blend = false,
            .vtx_buff_desc = .{
                .attribute_description = @constCast(&VtxBuffDesc.attribute_description)[0..],
                .binding_description = VtxBuffDesc.binding_description,
            },
            .push_constant_ranges = &.{},
            .descriptor_set_layouts = &.{},
        };
        const vk_pipeline = try vk.pipe.VkPipeline.create(allocator, vk_ctx, &vk_pipelineCreateInfo);

        return .{
            .vk_pipeline = vk_pipeline,
        };
    }

    /// Records draw commands into `vk_cmd`: begins dynamic rendering, binds the
    /// pipeline, sets viewport/scissor, then draws every mesh in `models_cache`.
    pub fn render(self: *RenderScn, vk_ctx: *const vk.ctx.VkCtx, vk_cmd: vk.cmd.VkCmdBuff, models_cache: *const mcach.ModelsCache, image_index: u32) !void {
        const cmd_handle = vk_cmd.cmd_buff_proxy.handle;
        const device = vk_ctx.vk_device.device_proxy;

        const render_att_info = vulkan.RenderingAttachmentInfo{
            .image_view = vk_ctx.vk_swap_chain.image_views[image_index].view,
            .image_layout = vulkan.ImageLayout.attachment_optimal_khr,
            .load_op = vulkan.AttachmentLoadOp.clear,
            .store_op = vulkan.AttachmentStoreOp.store,
            .clear_value = vulkan.ClearValue{ .color = .{ .float_32 = .{ 0.0, 0.0, 0.0, 1.0 } } },
            .resolve_mode = vulkan.ResolveModeFlags{},
            .resolve_image_layout = vulkan.ImageLayout.attachment_optimal_khr,
        };

        const extent = vk_ctx.vk_swap_chain.extent;
        const render_info = vulkan.RenderingInfo{
            .render_area = .{ .extent = extent, .offset = .{ .x = 0, .y = 0 } },
            .layer_count = 1,
            .color_attachment_count = 1,
            .p_color_attachments = &[_]vulkan.RenderingAttachmentInfo{render_att_info},
            .view_mask = 0,
        };

        device.cmdBeginRendering(cmd_handle, @ptrCast(&render_info));

        device.cmdBindPipeline(cmd_handle, vulkan.PipelineBindPoint.graphics, self.vk_pipeline.pipeline);

        const view_port = [_]vulkan.Viewport{.{
            .x = 0,
            .y = @as(f32, @floatFromInt(extent.height)),
            .width = @as(f32, @floatFromInt(extent.width)),
            .height = -1.0 * @as(f32, @floatFromInt(extent.height)),
            .min_depth = 0,
            .max_depth = 1,
        }};
        device.cmdSetViewport(cmd_handle, 0, view_port.len, &view_port);
        const scissor = [_]vulkan.Rect2D{.{
            .offset = vulkan.Offset2D{ .x = 0, .y = 0 },
            .extent = vulkan.Extent2D{ .width = extent.width, .height = extent.height },
        }};
        device.cmdSetScissor(cmd_handle, 0, scissor.len, &scissor);

        const offset = [_]vulkan.DeviceSize{0};
        var iter = models_cache.models_map.valueIterator();
        while (iter.next()) |vulkan_ref| {
            for (vulkan_ref.meshes.items) |mesh| {
                device.cmdBindIndexBuffer(cmd_handle, mesh.buff_idx.buffer, 0, vulkan.IndexType.uint32);
                device.cmdBindVertexBuffers(cmd_handle, 0, 1, @ptrCast(&mesh.buff_vtx.buffer), &offset);
                device.cmdDrawIndexed(cmd_handle, @as(u32, @intCast(mesh.num_indices)), 1, 0, 0, 0);
            }
        }

        device.cmdEndRendering(cmd_handle);
    }
};
