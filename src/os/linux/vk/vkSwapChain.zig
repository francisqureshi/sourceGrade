const std = @import("std");
const sdl3 = @import("sdl3");
const vulkan = @import("vulkan");
const vk = @import("mod.zig");

const log = std.log.scoped(.vk);

pub const AcquireResult = union(enum) {
    ok: u32,
    recreate,
};

pub const VkSwapChain = struct {
    extent: vulkan.Extent2D,
    image_views: []vk.imv.VkImageView,
    surface_format: vulkan.SurfaceFormatKHR,
    handle: vulkan.SwapchainKHR,
    vsync: bool,

    pub fn acquire(
        self: *const VkSwapChain,
        device: vk.dev.VkDevice,
        semaphore: vk.sync.VkSemaphore,
    ) !AcquireResult {
        const res = device.device_proxy.acquireNextImageKHR(
            self.handle,
            std.math.maxInt(u64),
            semaphore.semaphore,
            .null_handle,
        );

        if (res) |ok| {
            return switch (ok.result) {
                .success, .suboptimal_khr => .{ .ok = ok.image_index },
                else => .recreate,
            };
        } else |err| {
            return switch (err) {
                error.OutOfDateKHR => .recreate,
                else => err,
            };
        }
    }

    fn calcExtent(window: sdl3.video.Window, caps: vulkan.SurfaceCapabilitiesKHR) !vulkan.Extent2D {
        if (caps.current_extent.width != std.math.maxInt(u32)) {
            return caps.current_extent;
        }

        const size = try sdl3.video.Window.getSizeInPixels(window);

        return .{
            .width = std.math.clamp(
                @as(u32, @intCast(size[0])),
                caps.min_image_extent.width,
                caps.max_image_extent.width,
            ),
            .height = std.math.clamp(
                @as(u32, @intCast(size[1])),
                caps.min_image_extent.height,
                caps.max_image_extent.height,
            ),
        };
    }

    fn calcNumImages(caps: vulkan.SurfaceCapabilitiesKHR, requested: u32) u32 {
        var count = if (requested > 0) requested else caps.min_image_count + 1;

        if (count < caps.min_image_count) {
            count = caps.min_image_count;
        }

        if (caps.max_image_count > 0 and count > caps.max_image_count) {
            count = caps.max_image_count;
        }

        return count;
    }

    pub fn cleanup(self: *const VkSwapChain, allocator: std.mem.Allocator, device: vk.dev.VkDevice) void {
        for (self.image_views) |*iv| {
            iv.cleanup(device);
        }
        allocator.free(self.image_views);
        device.device_proxy.destroySwapchainKHR(self.handle, null);
    }

    fn calcPresentMode(
        allocator: std.mem.Allocator,
        instance: vk.inst.VkInstance,
        phys_device: vk.phys.VkPhysDevice,
        surface: vulkan.SurfaceKHR,
        vsync: bool,
    ) !vulkan.PresentModeKHR {
        const modes = try instance.instance_proxy.getPhysicalDeviceSurfacePresentModesAllocKHR(
            phys_device.pdev,
            surface,
            allocator,
        );
        defer allocator.free(modes);

        if (!vsync) {
            for (modes) |m| {
                if (m == .mailbox_khr) return m;
            }
            for (modes) |m| {
                if (m == .immediate_khr) return m;
            }
        }

        return .fifo_khr;
    }

    pub fn create(
        allocator: std.mem.Allocator,
        window: sdl3.video.Window,
        instance: vk.inst.VkInstance,
        phys_device: vk.phys.VkPhysDevice,
        device: vk.dev.VkDevice,
        surface: vk.surf.VkSurface,
        req_images: u32,
        vsync: bool,
    ) !VkSwapChain {
        const caps = try surface.getSurfaceCaps(instance, phys_device);
        const image_count = calcNumImages(caps, req_images);
        const extent = try calcExtent(window, caps);
        const surface_format = try surface.getSurfaceFormat(allocator, instance, phys_device);
        const present_mode = try calcPresentMode(allocator, instance, phys_device, surface.surface, vsync);

        const same_family =
            phys_device.queues_info.graphics_family ==
            phys_device.queues_info.present_family;

        const qfi = [_]u32{
            phys_device.queues_info.graphics_family,
            phys_device.queues_info.present_family,
        };

        const swap_chain_info = vulkan.SwapchainCreateInfoKHR{
            .surface = surface.surface,
            .min_image_count = image_count,
            .image_format = surface_format.format,
            .image_color_space = surface_format.color_space,
            .image_extent = extent,
            .image_array_layers = 1,
            .image_usage = .{
                .color_attachment_bit = true,
            },
            .image_sharing_mode = if (same_family) .exclusive else .concurrent,
            .queue_family_index_count = if (same_family) 0 else qfi.len,
            .p_queue_family_indices = if (same_family) null else &qfi,
            .pre_transform = caps.current_transform,
            .composite_alpha = .{ .opaque_bit_khr = true },
            .present_mode = present_mode,
            .clipped = vulkan.Bool32.true,
            .old_swapchain = .null_handle,
        };

        const handle = try device.device_proxy.createSwapchainKHR(&swap_chain_info, null);

        const image_views = try createImageViews(
            allocator,
            device,
            handle,
            surface_format.format,
        );

        log.debug(
            "VkSwapChain created: {d} images, extent {d}x{d}, present mode {any}",
            .{ image_views.len, extent.width, extent.height, present_mode },
        );

        return .{
            .extent = extent,
            .image_views = image_views,
            .surface_format = surface_format,
            .handle = handle,
            .vsync = vsync,
        };
    }

    fn createImageViews(
        allocator: std.mem.Allocator,
        device: vk.dev.VkDevice,
        swap_chain: vulkan.SwapchainKHR,
        format: vulkan.Format,
    ) ![]vk.imv.VkImageView {
        const images = try device.device_proxy.getSwapchainImagesAllocKHR(swap_chain, allocator);
        defer allocator.free(images);

        const views = try allocator.alloc(vk.imv.VkImageView, images.len);

        const iv_data = vk.imv.VkImageViewData{ .format = format };

        var i: usize = 0;
        for (images) |img| {
            views[i] = try vk.imv.VkImageView.create(device, img, iv_data);
            i += 1;
        }

        return views;
    }

    pub fn present(
        self: *const VkSwapChain,
        device: vk.dev.VkDevice,
        queue: vk.queue.VkQueue,
        wait_sem: vk.sync.VkSemaphore,
        img_idx: u32,
    ) bool {
        const sems = [_]vulkan.Semaphore{wait_sem.semaphore};
        const swaps = [_]vulkan.SwapchainKHR{self.handle};
        const indices = [_]u32{img_idx};

        const info = vulkan.PresentInfoKHR{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = &sems,
            .swapchain_count = 1,
            .p_swapchains = &swaps,
            .p_image_indices = &indices,
        };

        const result = device.device_proxy.queuePresentKHR(queue.handle, &info) catch return false;

        return switch (result) {
            .success, .suboptimal_khr => true,
            else => false,
        };
    }
};
