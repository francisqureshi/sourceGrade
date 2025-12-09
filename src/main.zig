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
    var vertex_fn = try library.createFunction("vertexShaderBuffered");
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
    // Using extern struct with explicit alignment to match Metal's expectations
    const VertexData = extern struct {
        position: [2]f32 align(4),
        color: [4]f32 align(4),
    };

    // Colorful quad using triangle strip (4 vertices with corner colors)
    const vertices = [_]VertexData{
        .{ .position = .{ -0.5, 0.5 }, .color = .{ 1.0, 0.0, 0.0, 1.0 } },   // top-left: red
        .{ .position = .{ -0.5, -0.5 }, .color = .{ 0.0, 1.0, 0.0, 1.0 } },  // bottom-left: green
        .{ .position = .{ 0.5, 0.5 }, .color = .{ 0.0, 0.0, 1.0, 1.0 } },    // top-right: blue
        .{ .position = .{ 0.5, -0.5 }, .color = .{ 1.0, 1.0, 0.0, 1.0 } },   // bottom-right: yellow
    };
    const vertex_data_bytes = std.mem.sliceAsBytes(&vertices);
    var vertex_buffer = try device.createBuffer(@intCast(vertex_data_bytes.len));
    defer vertex_buffer.deinit();
    vertex_buffer.upload(vertex_data_bytes);
    std.debug.print("✓ Created vertex buffer ({} bytes)\n\n", .{vertex_data_bytes.len});

    // Initialize NSApplication (this must happen before showing window)
    c.metal_window_init_app();

    // Show the window
    c.metal_window_show(window);

    std.debug.print("🌀 Starting render loop...\n", .{});
    std.debug.print("Close the window or press Cmd+Q to quit.\n\n", .{});

    // Continuous render loop with rotation
    var frame: u64 = 0;
    const start_time = try std.time.Instant.now();

    while (true) : (frame += 1) {
        // Process events
        c.metal_window_process_events(window);

        // Calculate rotation angle (360 degrees every 3 seconds)
        const current_time = try std.time.Instant.now();
        const elapsed_ns = current_time.since(start_time);
        const elapsed_ms = elapsed_ns / std.time.ns_per_ms;
        const rotation_angle: f32 = @as(f32, @floatFromInt(elapsed_ms % 30000)) / 30000.0 * 2.0 * std.math.pi;

        // Get drawable
        const drawable_ptr = c.metal_layer_get_next_drawable(layer);
        if (drawable_ptr == null) continue;

        const texture_ptr = c.metal_drawable_get_texture(drawable_ptr);
        if (texture_ptr == null) continue;

        // Wrap texture
        var drawable_texture = metal.MetalTexture.initFromPtr(texture_ptr);

        // Create render pass
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

        // Set pipeline
        render_encoder.setPipeline(&pipeline);

        // Bind vertex buffer (buffer index 0)
        render_encoder.setVertexBuffer(&vertex_buffer, 0, 0);

        // Pass rotation angle to shader (buffer index 1)
        render_encoder.setVertexBytes(@ptrCast(&rotation_angle), @sizeOf(f32), 1);

        // Draw quad (4 vertices as triangle strip)
        render_encoder.drawPrimitives(.triangle_strip, 0, 4);
        render_encoder.end();

        // Schedule present and commit
        command_buffer.present(drawable_ptr);
        command_buffer.commit();

        if (frame == 0) {
            std.debug.print("✓ First frame rendered!\n", .{});
        }

        // ~60 FPS
        // std.posix.nanosleep(0, 16_000_000);
        // 120 FPS
        std.posix.nanosleep(0, 8_300_000);
    }
}
