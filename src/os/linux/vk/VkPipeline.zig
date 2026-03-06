const std = @import("std");
const vulkan = @import("vulkan");
const vk = @import("mod.zig");

pub const ShaderModuleInfo = struct {
    module: vulkan.ShaderModule,
    stage: vulkan.ShaderStageFlags,
};

pub const VkPipelineCreateInfo = struct {
    color_format: vulkan.Format,
    modules_info: []ShaderModuleInfo,
    use_blend: bool,
    vtx_buff_desc: VtxBuffDesc,
    push_constant_ranges: []const vulkan.PushConstantRange,
    descriptor_set_layouts: []const vulkan.DescriptorSetLayout,
};

const VtxBuffDesc = struct {
    binding_description: vulkan.VertexInputBindingDescription,
    attribute_description: []vulkan.VertexInputAttributeDescription,
};

pub const VkPipeline = struct {
    pipeline: vulkan.Pipeline,
    pipeline_layout: vulkan.PipelineLayout,

    pub fn create(allocator: std.mem.Allocator, vk_ctx: *const vk.ctx.VkCtx, createInfo: *const VkPipelineCreateInfo) !VkPipeline {
        const pssci = try allocator.alloc(vulkan.PipelineShaderStageCreateInfo, createInfo.modules_info.len);
        defer allocator.free(pssci);

        for (pssci, 0..) |*info, i| {
            info.* = .{
                .stage = createInfo.modules_info[i].stage,
                .module = createInfo.modules_info[i].module,
                .p_name = "main",
            };
        }

        const piasci = vulkan.PipelineInputAssemblyStateCreateInfo{
            .topology = .triangle_list,
            .primitive_restart_enable = vulkan.Bool32.false,
        };

        const pvsci = vulkan.PipelineViewportStateCreateInfo{
            .viewport_count = 1,
            .p_viewports = null,
            .scissor_count = 1,
            .p_scissors = null,
        };

        const prsci = vulkan.PipelineRasterizationStateCreateInfo{
            .depth_clamp_enable = vulkan.Bool32.false,
            .rasterizer_discard_enable = vulkan.Bool32.false,
            .polygon_mode = .fill,
            .cull_mode = .{},
            .front_face = .clockwise,
            .depth_bias_enable = vulkan.Bool32.false,
            .depth_bias_constant_factor = 0,
            .depth_bias_clamp = 0,
            .depth_bias_slope_factor = 0,
            .line_width = 1,
        };

        const pmsci = vulkan.PipelineMultisampleStateCreateInfo{
            .rasterization_samples = .{ .@"1_bit" = true },
            .sample_shading_enable = vulkan.Bool32.false,
            .min_sample_shading = 0,
            .alpha_to_coverage_enable = vulkan.Bool32.false,
            .alpha_to_one_enable = vulkan.Bool32.false,
        };

        const dynstate = [_]vulkan.DynamicState{ .viewport, .scissor };
        const pdsci = vulkan.PipelineDynamicStateCreateInfo{
            .flags = .{},
            .dynamic_state_count = dynstate.len,
            .p_dynamic_states = &dynstate,
        };

        const pcbas = vulkan.PipelineColorBlendAttachmentState{
            .blend_enable = if (createInfo.use_blend) vulkan.Bool32.true else vulkan.Bool32.false,
            .color_blend_op = .add,
            .src_color_blend_factor = .src_alpha,
            .dst_color_blend_factor = .one_minus_src_alpha,
            .alpha_blend_op = .add,
            .src_alpha_blend_factor = .src_alpha,
            .dst_alpha_blend_factor = .zero,
            .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
        };

        const pcbsci = vulkan.PipelineColorBlendStateCreateInfo{
            .logic_op_enable = vulkan.Bool32.false,
            .logic_op = .copy,
            .attachment_count = 1,
            .p_attachments = &[_]vulkan.PipelineColorBlendAttachmentState{pcbas},
            .blend_constants = [_]f32{ 0, 0, 0, 0 },
        };

        const formats = [_]vulkan.Format{createInfo.color_format};
        const renderCreateInfo = vulkan.PipelineRenderingCreateInfo{
            .color_attachment_count = 1,
            .p_color_attachment_formats = &formats,
            .view_mask = 0,
            .depth_attachment_format = vulkan.Format.undefined,
            .stencil_attachment_format = vulkan.Format.undefined,
        };

        const pvisci = vulkan.PipelineVertexInputStateCreateInfo{
            .vertex_binding_description_count = 1,
            .p_vertex_binding_descriptions = @ptrCast(&createInfo.vtx_buff_desc.binding_description),
            .vertex_attribute_description_count = @intCast(createInfo.vtx_buff_desc.attribute_description.len),
            .p_vertex_attribute_descriptions = createInfo.vtx_buff_desc.attribute_description.ptr,
        };

        const pipeline_layout = try vk_ctx.vk_device.device_proxy.createPipelineLayout(&.{
            .flags = .{},
            .set_layout_count = @intCast(createInfo.descriptor_set_layouts.len),
            .p_set_layouts = createInfo.descriptor_set_layouts.ptr,
            .push_constant_range_count = @intCast(createInfo.push_constant_ranges.len),
            .p_push_constant_ranges = createInfo.push_constant_ranges.ptr,
        }, null);

        const gpci = vulkan.GraphicsPipelineCreateInfo{
            .flags = .{},
            .stage_count = @intCast(createInfo.modules_info.len),
            .p_stages = pssci.ptr,
            .p_vertex_input_state = &pvisci,
            .p_input_assembly_state = &piasci,
            .p_tessellation_state = null,
            .p_viewport_state = &pvsci,
            .p_rasterization_state = &prsci,
            .p_multisample_state = &pmsci,
            .p_depth_stencil_state = null,
            .p_color_blend_state = &pcbsci,
            .p_dynamic_state = &pdsci,
            .layout = pipeline_layout,
            .subpass = 0,
            .base_pipeline_handle = .null_handle,
            .base_pipeline_index = -1,
            .p_next = @constCast(&renderCreateInfo),
        };

        var pipeline: vulkan.Pipeline = undefined;
        _ = try vk_ctx.vk_device.device_proxy.createGraphicsPipelines(
            .null_handle,
            1,
            @ptrCast(&gpci),
            null,
            @ptrCast(&pipeline),
        );

        return .{ .pipeline = pipeline, .pipeline_layout = pipeline_layout };
    }

    pub fn cleanup(self: *VkPipeline, vk_ctx: *const vk.ctx.VkCtx) void {
        vk_ctx.vk_device.device_proxy.destroyPipeline(self.pipeline, null);
        vk_ctx.vk_device.device_proxy.destroyPipelineLayout(self.pipeline_layout, null);
    }
};
