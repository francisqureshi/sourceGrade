const std = @import("std");
const vulkan = @import("vulkan");
const vk = @import("mod.zig");

const log = std.log.scoped(.vk);
const reqExtensions = [_][*:0]const u8{vulkan.extensions.khr_swapchain.name};

pub const VkDevice = struct {
    device_proxy: vulkan.DeviceProxy,

    /// Creates the logical device. Enables graphics and present queues (1 queue each,
    /// deduplicated if they share the same family), VK_KHR_swapchain extension,
    /// and Vulkan 1.2/1.3 features (dynamic rendering, synchronization2, anisotropy).
    pub fn create(
        allocator: std.mem.Allocator,
        vk_instance: vk.inst.VkInstance,
        vk_phys_device: vk.phys.VkPhysDevice,
    ) !VkDevice {
        const priority = [_]f32{0};
        const qci = [_]vulkan.DeviceQueueCreateInfo{
            .{
                .queue_family_index = vk_phys_device.queues_info.graphics_family,
                .queue_count = 1,
                .p_queue_priorities = &priority,
            },
            .{
                .queue_family_index = vk_phys_device.queues_info.present_family,
                .queue_count = 1,
                .p_queue_priorities = &priority,
            },
        };

        const queueCount: u32 = if (vk_phys_device.queues_info.graphics_family == vk_phys_device.queues_info.present_family)
            1
        else
            2;

        const features3 = vulkan.PhysicalDeviceVulkan13Features{
            .dynamic_rendering = vulkan.Bool32.true,
            .synchronization_2 = vulkan.Bool32.true,
        };
        const features2 = vulkan.PhysicalDeviceVulkan12Features{
            .p_next = @constCast(&features3),
        };
        const features = vulkan.PhysicalDeviceFeatures{
            .sampler_anisotropy = vk_phys_device.features.sampler_anisotropy,
        };

        const devCreateInfo: vulkan.DeviceCreateInfo = .{
            .queue_create_info_count = queueCount,
            .p_next = @ptrCast(&features2),
            .p_queue_create_infos = &qci,
            .enabled_extension_count = reqExtensions.len,
            .pp_enabled_extension_names = reqExtensions[0..].ptr,
            .p_enabled_features = @ptrCast(&features),
        };
        const device = try vk_instance.instance_proxy.createDevice(vk_phys_device.pdev, &devCreateInfo, null);

        const vkd = try allocator.create(vulkan.DeviceWrapper);
        vkd.* = vulkan.DeviceWrapper.load(device, vk_instance.instance_proxy.wrapper.dispatch.vkGetDeviceProcAddr.?);
        const device_proxy = vulkan.DeviceProxy.init(device, vkd);

        return .{ .device_proxy = device_proxy };
    }

    /// Destroys the logical device and frees the heap-allocated DeviceWrapper dispatch table.
    pub fn cleanup(self: *VkDevice, allocator: std.mem.Allocator) void {
        log.debug("Destroying Vulkan Device", .{});
        self.device_proxy.destroyDevice(null);
        allocator.destroy(self.device_proxy.wrapper);
    }

    /// Blocks until all submitted work on this device has completed.
    /// Call before cleanup to avoid destroying resources still in use by the GPU.
    pub fn wait(self: *VkDevice) !void {
        try self.device_proxy.deviceWaitIdle();
    }
};
