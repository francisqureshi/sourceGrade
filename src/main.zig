const std = @import("std");
const metal = @import("metal");
const imgui = @import("imgui.zig");

// Import the Swift AppKit bridge
const c = @cImport({
    @cInclude("metal_window.h");
});

pub fn main() !void {
    std.debug.print("=== Metal IMGUI with Dynamic Ring Buffers ===\n\n", .{});

    // Setup allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

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
    std.debug.print("✓ Created render pipeline\n", .{});

    // Create IMGUI pipeline with alpha blending
    var imgui_vertex_fn = try library.createFunction("imguiVertexShader");
    defer imgui_vertex_fn.deinit();

    var imgui_fragment_fn = try library.createFunction("imguiFragmentShader");
    defer imgui_fragment_fn.deinit();

    const imgui_pipeline_desc = metal.RenderPipelineDescriptor{
        .pixel_format = .bgra8_unorm,
        .blend_enabled = true, // Enable alpha blending for UI
    };

    var imgui_pipeline = try imgui_vertex_fn.createRenderPipeline(&device, &imgui_fragment_fn, imgui_pipeline_desc);
    defer imgui_pipeline.deinit();
    std.debug.print("✓ Created IMGUI render pipeline\n\n", .{});

    // Create vertex buffer with triangle data
    // Using extern struct with explicit alignment to match Metal's expectations
    const VertexData = extern struct {
        position: [2]f32 align(4),
        color: [4]f32 align(4),
    };

    // Single buffer for ALL geometry (quad + line)
    const all_vertices = [_]VertexData{
        // Quad (4 vertices for triangle strip)
        .{ .position = .{ -0.5, 0.5 }, .color = .{ 1.0, 0.0, 0.0, 1.0 } }, // top-left: red
        .{ .position = .{ -0.5, -0.5 }, .color = .{ 0.0, 1.0, 0.0, 1.0 } }, // bottom-left: green
        .{ .position = .{ 0.5, 0.5 }, .color = .{ 0.0, 0.0, 1.0, 1.0 } }, // top-right: blue
        .{ .position = .{ 0.5, -0.5 }, .color = .{ 1.0, 1.0, 0.0, 1.0 } }, // bottom-right: yellow
        // Line (2 vertices)
        .{ .position = .{ -0.6, 0.7 }, .color = .{ 1.0, 1.0, 1.0, 1.0 } }, // left point: white
        .{ .position = .{ 0.6, 0.7 }, .color = .{ 1.0, 1.0, 1.0, 1.0 } }, // right point: white
    };

    const vertex_data_bytes = std.mem.sliceAsBytes(&all_vertices);
    var vertex_buffer = try device.createBuffer(@intCast(vertex_data_bytes.len));
    defer vertex_buffer.deinit();
    vertex_buffer.upload(vertex_data_bytes);

    std.debug.print("✓ Created vertex buffer ({} bytes, {} vertices)\n", .{ vertex_data_bytes.len, all_vertices.len });

    // Initialize IMGUI context with ring buffers
    var imgui_ctx = try imgui.ImGuiContext.init(allocator, &device);
    defer imgui_ctx.deinit();
    imgui_ctx.display_width = 800;
    imgui_ctx.display_height = 600;
    std.debug.print("✓ Created IMGUI context (triple-buffered)\n\n", .{});

    // Initialize NSApplication (this must happen before showing window)
    c.metal_window_init_app();

    // Show the window
    c.metal_window_show(window);

    std.debug.print("🌀 Starting render loop...\n", .{});
    std.debug.print("Close the window or press Cmd+Q to quit.\n\n", .{});

    // Continuous render loop with rotation
    var frame: u64 = 0;
    const start_time = try std.time.Instant.now();

    // UI state
    var button_click_count: u32 = 0;
    var slider_value: f32 = 0.5;

    while (true) : (frame += 1) {
        // Process events
        c.metal_window_process_events(window);

        // Calculate rotation angle (360 degrees every 3 seconds)
        const current_time = try std.time.Instant.now();
        const elapsed_ns = current_time.since(start_time);
        const elapsed_ms = elapsed_ns / std.time.ns_per_ms;
        const rotation_angle: f32 = @as(f32, @floatFromInt(elapsed_ms % 30000)) / 30000.0 * 2.0 * std.math.pi;

        // Build IMGUI frame (immediate-mode pattern)
        imgui_ctx.newFrame();

        // TODO: Get real mouse input from events
        // For now, use dummy values (you'll add event handling next)
        imgui_ctx.mouse_x = 400;
        imgui_ctx.mouse_y = 300;
        imgui_ctx.mouse_down = false;

        // Add some UI elements
        if (try imgui_ctx.button(1, 300, 250, 200, 60, "Click Me!")) {
            button_click_count += 1;
            std.debug.print("Button clicked! Count: {}\n", .{button_click_count});
        }

        try imgui_ctx.slider(2, 100, 400, 600, 20, &slider_value, 0.0, 1.0);

        // Add some colored rectangles
        try imgui_ctx.addRect(50, 50, 100, 100, imgui.ImGuiContext.packColor(1, 0, 0, 0.8));
        try imgui_ctx.addRect(600, 50, 100, 100, imgui.ImGuiContext.packColor(0, 1, 0, 0.8));

        // Add a line
        try imgui_ctx.addLine(50, 500, 750, 500, imgui.ImGuiContext.packColor(1, 1, 1, 1), 2.0);

        // Upload IMGUI geometry to GPU
        imgui_ctx.render();

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

        // ===== Layer 1: Background rotating quad (old demo) =====
        render_encoder.setPipeline(&pipeline);
        render_encoder.setVertexBuffer(&vertex_buffer, 0, 0);
        render_encoder.setVertexBytes(@ptrCast(&rotation_angle), @sizeOf(f32), 1);
        render_encoder.drawPrimitives(.triangle_strip, 0, 4);
        render_encoder.drawPrimitives(.line, 4, 2);

        // ===== Layer 2: IMGUI (UI overlay with alpha blending) =====
        const imgui_index_count = imgui_ctx.getIndexCount();
        if (imgui_index_count > 0) {
            render_encoder.setPipeline(&imgui_pipeline);

            // Bind IMGUI buffers (from previous frame, due to ring buffer)
            const imgui_vb = imgui_ctx.getVertexBuffer();
            const imgui_ib = imgui_ctx.getIndexBuffer();
            render_encoder.setVertexBuffer(imgui_vb, 0, 0);

            // Pass screen size for coordinate conversion
            const screen_size = [2]f32{ imgui_ctx.display_width, imgui_ctx.display_height };
            render_encoder.setVertexBytes(@ptrCast(&screen_size), @sizeOf([2]f32), 1);

            // Draw all UI geometry using indexed primitives (efficient!)
            render_encoder.drawIndexedPrimitives(.triangle, imgui_index_count, imgui_ib, 0);
        }

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
