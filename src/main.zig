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

    // Create window (800x600, normal window with title bar)
    const window = c.metal_window_create(800, 600, false);
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
        .{ .position = .{ 0.0, 0.2 }, .color = .{ 1.0, 0.0, 0.0, 1.0 } }, // Top (red) - move down
        .{ .position = .{ -0.3, -0.2 }, .color = .{ 0.0, 1.0, 0.0, 1.0 } }, // Bottom-left (green) - move up
        .{ .position = .{ 0.3, -0.2 }, .color = .{ 0.0, 0.0, 1.0, 1.0 } }, // Bottom-right (blue) - move up
    };

    var vertex_buffer = try device.createBuffer(@sizeOf(@TypeOf(vertices)));
    defer vertex_buffer.deinit();
    vertex_buffer.upload(std.mem.sliceAsBytes(&vertices));

    std.debug.print("Triangle ready to render!\n", .{});
    std.debug.print("Showing window and starting AppKit main loop...\n", .{});

    // Show the window
    c.metal_window_show(window);

    // Render a few frames to show triangle is working
    for (0..5) |frame| {
        std.debug.print("Rendering frame {}\n", .{frame});

        // Get next drawable from CAMetalLayer
        const drawable_ptr = c.metal_layer_get_next_drawable(layer);
        if (drawable_ptr == null) {
            std.debug.print("No drawable available\n", .{});
            continue;
        }

        // Create MetalDrawable wrapper
        var drawable = metal.MetalDrawable{ .handle = drawable_ptr };

        // Get texture from drawable
        var drawable_texture = drawable.getTexture();
        defer drawable_texture.deinit();

        // Create render pass descriptor
        var render_pass = metal.MetalRenderPassDescriptor.init();
        defer render_pass.deinit();
        render_pass.setColorTexture(&drawable_texture, 0);
        render_pass.setClearColor(0.0, 0.0, 0.0, 1.0, 0); // Black background

        // Create command buffer
        var command_buffer = try queue.createCommandBuffer();
        defer command_buffer.deinit();

        // Create render encoder
        var render_encoder = try command_buffer.createRenderEncoder(&render_pass);
        defer render_encoder.deinit();

        // Set render pipeline
        render_encoder.setPipeline(&pipeline);

        // Set vertex data directly instead of buffer
        render_encoder.setVertexBytes(&vertices, @sizeOf(@TypeOf(vertices)), 0);

        // Draw triangle
        render_encoder.drawPrimitives(.triangle, 0, 3);
        render_encoder.end();

        // Commit and present
        command_buffer.commit();
        drawable.present();

        // Process events
        c.metal_window_process_events(window);
    }

    std.debug.print("Starting AppKit main loop (window should be visible now)...\n", .{});

    // Run the AppKit main loop - this will block and handle events
    c.metal_window_run_app();

    std.debug.print("AppKit loop ended.\n", .{});
}
