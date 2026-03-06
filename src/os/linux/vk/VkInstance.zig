const std = @import("std");
const builtin = @import("builtin");

const sdl3 = @import("sdl3");
const vulkan = @import("vulkan");

const log = std.log.scoped(.vk);

const VALIDATION_LAYER = "VK_LAYER_KHRONOS_validation";

pub const VkInstance = struct {
    vkb: vulkan.BaseWrapper,
    debugMessenger: ?vulkan.DebugUtilsMessengerEXT = null,
    instance_proxy: vulkan.InstanceProxy,

    /// Creates the Vulkan instance. Loads the Vulkan function pointers via SDL3,
    /// adds SDL's required extensions, and optionally enables the Khronos validation
    /// layer + debug messenger when `validate` is true.
    pub fn create(allocator: std.mem.Allocator, validate: bool) !VkInstance {
        const rawProc = sdl3.vulkan.getVkGetInstanceProcAddr() catch |err| {
            std.debug.print("Vulkan not available: {}\n", .{err});
            return err;
        };

        const loader: vulkan.PfnGetInstanceProcAddr = @ptrCast(rawProc);
        const vkb = vulkan.BaseWrapper.load(loader);

        const appInfo = vulkan.ApplicationInfo{
            .p_application_name = "sourceGrade",
            .application_version = @bitCast(vulkan.makeApiVersion(0, 1, 0, 0)),
            .p_engine_name = "sourceGrade",
            .engine_version = @bitCast(vulkan.makeApiVersion(0, 1, 0, 0)),
            .api_version = @bitCast(vulkan.API_VERSION_1_3),
        };

        var extensionNames = try std.ArrayList([*:0]const u8).initCapacity(allocator, 2);
        defer extensionNames.deinit(allocator);
        const sdlExtensions = try sdl3.vulkan.getInstanceExtensions();
        try extensionNames.appendSlice(allocator, sdlExtensions);
        const is_macos = builtin.target.os.tag == .macos;
        if (is_macos) {
            try extensionNames.append("VK_KHR_portability_enumeration");
        }

        var layerNames = try std.ArrayList([*:0]const u8).initCapacity(allocator, 2);
        defer layerNames.deinit(allocator);

        const supValidation = try supportsValidation(allocator, &vkb);
        if (validate) {
            if (supValidation) {
                log.debug("Enabling validation", .{});
                try layerNames.append(allocator, VALIDATION_LAYER);
                try extensionNames.append(allocator, vulkan.extensions.ext_debug_utils.name);
            } else {
                log.debug("Validation layer not supported. Make sure Vulkan SDK is installed", .{});
            }
        }
        for (extensionNames.items) |value| {
            log.debug("Instance create extension: {s}", .{value});
        }

        const createInfo = vulkan.InstanceCreateInfo{
            .p_application_info = &appInfo,
            .enabled_extension_count = @intCast(extensionNames.items.len),
            .pp_enabled_extension_names = extensionNames.items.ptr,
            .enabled_layer_count = @intCast(layerNames.items.len),
            .pp_enabled_layer_names = layerNames.items.ptr,
            .flags = .{ .enumerate_portability_bit_khr = is_macos },
        };
        const instance = try vkb.createInstance(&createInfo, null);

        const vki = try allocator.create(vulkan.InstanceWrapper);
        vki.* = vulkan.InstanceWrapper.load(instance, vkb.dispatch.vkGetInstanceProcAddr.?);
        const instance_proxy = vulkan.InstanceProxy.init(instance, vki);

        var debugMessenger: ?vulkan.DebugUtilsMessengerEXT = null;
        if (validate and supValidation) {
            debugMessenger = try instance_proxy.createDebugUtilsMessengerEXT(&.{
                .message_severity = .{
                    .warning_bit_ext = true,
                    .error_bit_ext = true,
                },
                .message_type = .{
                    .general_bit_ext = true,
                    .validation_bit_ext = true,
                    .performance_bit_ext = true,
                },
                .pfn_user_callback = &VkInstance.debugUtilsMessengerCallback,
                .p_user_data = null,
            }, null);
        }

        return .{
            .vkb = vkb,
            .debugMessenger = debugMessenger,
            .instance_proxy = instance_proxy,
        };
    }

    /// Validation layer callback. Routes Vulkan messages to Zig's scoped logger
    /// at the appropriate severity level (err/warn/info/debug).
    fn debugUtilsMessengerCallback(
        severity: vulkan.DebugUtilsMessageSeverityFlagsEXT,
        msgType: vulkan.DebugUtilsMessageTypeFlagsEXT,
        callback_data: ?*const vulkan.DebugUtilsMessengerCallbackDataEXT,
        _: ?*anyopaque,
    ) callconv(.c) vulkan.Bool32 {
        _ = msgType;
        const message: [*c]const u8 = if (callback_data) |cb_data| cb_data.p_message else "NO MESSAGE!";
        if (severity.error_bit_ext) {
            log.err("{s}", .{message});
        } else if (severity.warning_bit_ext) {
            log.warn("{s}", .{message});
        } else if (severity.info_bit_ext) {
            log.info("{s}", .{message});
        } else {
            log.debug("{s}", .{message});
        }
        return vulkan.Bool32.false;
    }

    /// Destroys the debug messenger (if active), the instance, and frees the
    /// heap-allocated InstanceWrapper dispatch table.
    pub fn cleanup(self: *VkInstance, allocator: std.mem.Allocator) !void {
        log.debug("Destroying Vulkan instance", .{});
        if (self.debugMessenger) |dbg| {
            self.instance_proxy.destroyDebugUtilsMessengerEXT(dbg, null);
        }
        self.instance_proxy.destroyInstance(null);
        allocator.destroy(self.instance_proxy.wrapper);
        self.instance_proxy = undefined;
    }

    /// Returns true if VK_LAYER_KHRONOS_validation is available on this system.
    fn supportsValidation(allocator: std.mem.Allocator, vkb: *const vulkan.BaseWrapper) !bool {
        var result = false;
        var numLayers: u32 = 0;
        _ = try vkb.enumerateInstanceLayerProperties(&numLayers, null);

        const layers = try allocator.alloc(vulkan.LayerProperties, numLayers);
        defer allocator.free(layers);
        _ = try vkb.enumerateInstanceLayerProperties(&numLayers, layers.ptr);

        for (layers) |layerProps| {
            const layerName = std.mem.sliceTo(&layerProps.layer_name, 0);
            log.debug("Supported layer [{s}]", .{layerName});
            if (std.mem.eql(u8, layerName, VALIDATION_LAYER)) {
                result = true;
            }
        }

        return result;
    }
};
