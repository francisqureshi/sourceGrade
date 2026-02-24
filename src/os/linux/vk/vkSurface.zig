const std = @import("std");
const sdl3 = @import("sdl3");
const vulkan = @import("vulkan");
const vk = @import("mod.zig");

const log = std.log.scoped(.vk);

pub const VkSurface = struct {
    surface: vulkan.SurfaceKHR,

    /// Destroys the Vulkan surface. Must be called before destroying the instance.
    pub fn cleanup(self: *VkSurface, vkInstance: vk.inst.VkInstance) void {
        vkInstance.instanceProxy.destroySurfaceKHR(self.surface, null);
    }

    /// Creates a Vulkan surface from an SDL3 window via SDL_Vulkan_CreateSurface.
    /// Bridges the SDL window handle to a VkSurfaceKHR for rendering.
    pub fn create(window: sdl3.video.Window, vkInstance: vk.inst.VkInstance) !VkSurface {
        const vkHandle = vkInstance.instanceProxy.handle;
        const instancePtr: ?*sdl3.c.struct_VkInstance_T = @ptrFromInt(@intFromEnum(vkHandle));

        const surface = sdl3.vulkan.Surface.init(window, instancePtr, null) catch |err| {
            const sdlError = sdl3.c.SDL_GetError();
            log.err("Failed to create Vulkan surface. SDL Error: {s}, Zig Error: {}", .{ sdlError, err });
            return err;
        };

        return .{ .surface = @enumFromInt(@intFromPtr(surface.surface)) };
    }

    /// Queries surface capabilities: min/max image count, supported extents, and transforms.
    pub fn getSurfaceCaps(self: *const VkSurface, vkInstance: vk.inst.VkInstance, vkPhysDevice: vk.phys.VkPhysDevice) !vulkan.SurfaceCapabilitiesKHR {
        return try vkInstance.instanceProxy.getPhysicalDeviceSurfaceCapabilitiesKHR(vkPhysDevice.pdev, self.surface);
    }

    /// Selects the surface format. Prefers B8G8R8A8_SRGB + sRGB colorspace.
    /// Falls back to the first available format if the preferred one is not supported.
    pub fn getSurfaceFormat(
        self: *const VkSurface,
        allocator: std.mem.Allocator,
        vkInstance: vk.inst.VkInstance,
        vkPhysDevice: vk.phys.VkPhysDevice,
    ) !vulkan.SurfaceFormatKHR {
        const preferred = vulkan.SurfaceFormatKHR{
            .format = .b8g8r8a8_srgb,
            .color_space = .srgb_nonlinear_khr,
        };

        const surfaceFormats = try vkInstance.instanceProxy.getPhysicalDeviceSurfaceFormatsAllocKHR(
            vkPhysDevice.pdev,
            self.surface,
            allocator,
        );
        defer allocator.free(surfaceFormats);

        for (surfaceFormats) |sfmt| {
            if (std.meta.eql(sfmt, preferred)) {
                return preferred;
            }
        }

        if (surfaceFormats.len == 0) {
            return error.NoSurfaceFormats;
        }

        return surfaceFormats[0];
    }
};
