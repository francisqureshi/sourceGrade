const std = @import("std");
const metal = @import("metal");

// Import the Swift AppKit bridge
const c = @cImport({
    @cInclude("metal_window.h");
});

pub fn main() !void {
    std.debug.print("=== Metal Triangle with AppKit Window ===\n\n", .{});

    // Check if Metal is available
    if (!metal.isAvailable()) {
        std.debug.print("Error: Metal is not available on this system\n", .{});
        return error.MetalNotAvailable;
    }

    // Create the window (800x600, borderless = false for normal window)
    // Change to `true` for borderless window
    const window = c.metal_window_create(800, 600, true);
    if (window == null) {
        std.debug.print("Failed to create window\n", .{});
        return error.WindowCreationFailed;
    }
    defer c.metal_window_release(window);

    std.debug.print("✓ Created Metal window\n", .{});

    // Get the CAMetalLayer from the window
    const layer = c.metal_window_get_layer(window);
    if (layer == null) {
        std.debug.print("Failed to get Metal layer\n", .{});
        return error.LayerNotFound;
    }

    std.debug.print("✓ Got CAMetalLayer from window\n", .{});

    // Get the MTLDevice
    const device_ptr = c.metal_window_get_device(window);
    if (device_ptr == null) {
        std.debug.print("Failed to get Metal device\n", .{});
        return error.DeviceNotFound;
    }

    std.debug.print("✓ Got MTLDevice\n", .{});

    // Create Metal device wrapper from the existing device
    var device = try metal.MetalDevice.init();
    defer device.deinit();

    // Create command queue
    var queue = try device.createCommandQueue();
    defer queue.deinit();
    std.debug.print("✓ Created command queue\n", .{});

    // Load shaders
    const shader_source = @embedFile("Shaders.metal");
    var library = try device.createLibraryFromSource(shader_source);
    defer library.deinit();
    std.debug.print("✓ Compiled shader library\n", .{});

    // Get shader functions
    var vertex_fn = try library.createFunction("vertexShader");
    defer vertex_fn.deinit();

    var fragment_fn = try library.createFunction("fragmentShader");
    defer fragment_fn.deinit();
    std.debug.print("✓ Loaded vertex and fragment shaders\n", .{});

    // Create render pipeline descriptor
    const pipeline_desc = metal.RenderPipelineDescriptor{
        .pixel_format = .bgra8_unorm,
        .blend_enabled = false,
    };

    var pipeline = try vertex_fn.createRenderPipeline(&device, &fragment_fn, pipeline_desc);
    defer pipeline.deinit();
    std.debug.print("✓ Created render pipeline\n\n", .{});

    // Create vertex buffer with triangle data
    const VertexData = extern struct {
        position: [2]f32,
        color: [4]f32,
    };

    const vertices = [_]VertexData{
        .{ .position = .{ 0.0, 0.5 }, .color = .{ 1.0, 0.0, 0.0, 1.0 } }, // Top (red)
        .{ .position = .{ -0.5, -0.5 }, .color = .{ 0.0, 1.0, 0.0, 1.0 } }, // Bottom-left (green)
        .{ .position = .{ 0.5, -0.5 }, .color = .{ 0.0, 0.0, 1.0, 1.0 } }, // Bottom-right (blue)
    };

    var vertex_buffer = try device.createBuffer(@sizeOf(@TypeOf(vertices)));
    defer vertex_buffer.deinit();
    vertex_buffer.upload(std.mem.sliceAsBytes(&vertices));

    std.debug.print("Triangle ready to render!\n", .{});
    std.debug.print("Window is visible. The rendering loop would go here.\n", .{});
    std.debug.print("Press Cmd+Q to quit.\n\n", .{});

    // Show the window
    c.metal_window_show(window);

    // TODO: Implement render loop with CAMetalLayer
    // For now, just run the app event loop
    c.metal_window_run_app();
}
