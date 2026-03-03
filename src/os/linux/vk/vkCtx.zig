const std = @import("std");

const com = @import("com");
const sdl3 = @import("sdl3");
const vulkan = @import("vulkan");

const vk = @import("mod.zig");

pub const VkCtx = struct {
    constants: com.common.Constants,
    vk_device: vk.dev.VkDevice,
    vk_instance: vk.inst.VkInstance,
    vk_phys_device: vk.phys.VkPhysDevice,
    vk_surface: vk.surf.VkSurface,
    vk_swap_chain: vk.swap.VkSwapChain,

    /// Top-level factory. Creates all Vulkan objects in dependency order:
    /// instance → surface → physical device → logical device → swapchain.
    pub fn create(allocator: std.mem.Allocator, constants: com.common.Constants, window: sdl3.video.Window) !VkCtx {
        const vk_instance = try vk.inst.VkInstance.create(allocator, constants.validation);
        const vk_surface = try vk.surf.VkSurface.create(window, vk_instance);
        const vk_phys_device = try vk.phys.VkPhysDevice.create(
            allocator,
            constants,
            vk_instance.instance_proxy,
            vk_surface,
        );
        const vk_device = try vk.dev.VkDevice.create(allocator, vk_instance, vk_phys_device);
        const vk_swap_chain = try vk.swap.VkSwapChain.create(
            allocator,
            window,
            vk_instance,
            vk_phys_device,
            vk_device,
            vk_surface,
            constants.swap_chain_images,
            constants.vsync,
        );

        return .{
            .constants = constants,
            .vk_device = vk_device,
            .vk_instance = vk_instance,
            .vk_phys_device = vk_phys_device,
            .vk_surface = vk_surface,
            .vk_swap_chain = vk_swap_chain,
        };
    }

    pub fn findMemoryTypeIndex(self: *const VkCtx, mem_type_bits: u32, flags: vulkan.MemoryPropertyFlags) !u32 {
        const mem_props = self.vk_instance.instance_proxy.getPhysicalDeviceMemoryProperties(self.vk_phys_device.pdev);
        for (mem_props.memory_types[0..mem_props.memory_type_count], 0..) |mem_type, i| {
            if (mem_type_bits & (@as(u32, 1) << @truncate(i)) != 0 and mem_type.property_flags.contains(flags)) {
                return @truncate(i);
            }
        }

        return error.NoSuitableMemoryType;
    }

    /// Destroys all Vulkan objects in reverse creation order.
    pub fn cleanup(self: *VkCtx, allocator: std.mem.Allocator) !void {
        self.vk_swap_chain.cleanup(allocator, self.vk_device);
        self.vk_device.cleanup(allocator);
        self.vk_surface.cleanup(self.vk_instance);
        try self.vk_instance.cleanup(allocator);
    }
};
