const vk = @import("mod.zig");
const vulkan = @import("vulkan");

pub const VkImageViewConfig = struct {
    aspect_mask: vulkan.ImageAspectFlags = vulkan.ImageAspectFlags{ .color_bit = true },
    base_array_layer: u32 = 0,
    base_mip_level: u32 = 0,
    format: vulkan.Format,
    layer_count: u32 = 1,
    level_count: u32 = 1,
    view_type: vulkan.ImageViewType = .@"2d",
};

pub const VkImageView = struct {
    image: vulkan.Image,
    view: vulkan.ImageView,

    /// Creates a VkImageView for the given image. VkImageViewConfig configures format,
    /// aspect mask, mip/layer ranges, and view type (defaults to 2D color).
    pub fn create(vk_device: vk.dev.VkDevice, image: vulkan.Image, image_view_data: VkImageViewConfig) !VkImageView {
        const createInfo = vulkan.ImageViewCreateInfo{
            .image = image,
            .view_type = image_view_data.view_type,
            .format = image_view_data.format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = image_view_data.aspect_mask,
                .base_mip_level = image_view_data.base_mip_level,
                .level_count = image_view_data.level_count,
                .base_array_layer = image_view_data.base_array_layer,
                .layer_count = image_view_data.layer_count,
            },
            .p_next = null,
        };
        const image_view = try vk_device.device_proxy.createImageView(&createInfo, null);

        return .{
            .image = image,
            .view = image_view,
        };
    }

    /// Destroys the image view handle. Does not destroy the underlying image
    /// (swapchain images are owned by the swapchain).
    pub fn cleanup(self: *VkImageView, vk_device: vk.dev.VkDevice) void {
        vk_device.device_proxy.destroyImageView(self.view, null);
        self.view = .null_handle;
    }
};
