const std = @import("std");
const metal = @import("metal");
const imgui = @import("imgui.zig");

// Import the Swift AppKit bridge
const c = @cImport({
    @cInclude("metal_window.h");
});

// Semaphore for display link synchronization
var frame_semaphore = std.Thread.Semaphore{};

// CVDisplayLink callback - called on CVDisplayLink's thread
export fn displayLinkCallback(_: ?*anyopaque) callconv(.c) void {
    frame_semaphore.post(); // Signal: frame ready!
}

// Render context - all state needed for rendering
const RenderContext = struct {
    window: *anyopaque,
    layer: *anyopaque,
    queue: metal.MetalCommandQueue,
    pipeline: metal.MetalRenderPipelineState,
    imgui_pipeline: metal.MetalRenderPipelineState,
    vertex_buffer: metal.MetalBuffer,
    index_buffer: metal.MetalBuffer,
    imgui_ctx: *imgui.ImGuiContext,
    displaylink: ?*anyopaque,
    start_time: std.time.Instant,
};

// Render thread entry point
fn renderThread(ctx: *RenderContext) void {
    var frame: u64 = 0;
    var button_click_count: u32 = 0;
    var speed: f32 = 3000;
    var slider_value: f32 = 0.5;
    var circle_slider: f32 = 100;

    while (true) : (frame += 1) {
        // Wait for vsync signal from CVDisplayLink
        frame_semaphore.wait();

        // Calculate rotation
        const current_time = std.time.Instant.now() catch continue;
        const elapsed_ns = current_time.since(ctx.start_time);
        const elapsed_ms = @as(f32, @floatFromInt(elapsed_ns / std.time.ns_per_ms));
        const rotation_angle: f32 = @mod(elapsed_ms, speed) / speed * 2.0 * std.math.pi;
        const translation = [2]f32{ 0.5, 0.0 };

        // Build IMGUI frame
        ctx.imgui_ctx.newFrame();

        // Get mouse input (thread-safe since it's just reading)
        var mouse_x: f32 = 0;
        var mouse_y: f32 = 0;
        var mouse_down: bool = false;
        c.metal_window_get_mouse_state(ctx.window, &mouse_x, &mouse_y, &mouse_down);

        ctx.imgui_ctx.mouse_x = mouse_x;
        ctx.imgui_ctx.mouse_y = mouse_y;
        ctx.imgui_ctx.mouse_down = mouse_down;

        // UI elements
        if (ctx.imgui_ctx.button(1, 300, 250, 200, 60, "Click Me!") catch false) {
            button_click_count += 1;
            std.debug.print("Button clicked! Count: {}\n", .{button_click_count});
        }

        ctx.imgui_ctx.slider(2, 100, 400, 600, 16, &slider_value, 0.0, 1.0) catch {};
        ctx.imgui_ctx.slider(3, 100, 450, 600, 16, &speed, 3000, 0.00001) catch {};
        ctx.imgui_ctx.slider(4, 100, 500, 600, 32, &circle_slider, 0.0, 400) catch {};

        ctx.imgui_ctx.addRect(600, 50, 100, 100, imgui.ImGuiContext.packColor(slider_value, 1, 0, 0.8)) catch {};
        ctx.imgui_ctx.addRect(650, 100, 100, 100, imgui.ImGuiContext.packColor(0, 0, 1, 0.5)) catch {};
        ctx.imgui_ctx.addTriangle(100, 50, 0, 100, 100, 100, imgui.ImGuiContext.packColor(1, 1, 0, 0.8)) catch {};
        ctx.imgui_ctx.addCircle(200, 300, circle_slider, 360, imgui.ImGuiContext.packColor(255, 200, 150, 1)) catch {};
        ctx.imgui_ctx.addLine(0, 599, 800, 599, imgui.ImGuiContext.packColor(1, 0, 0, 0.5), 2.0) catch {};

        ctx.imgui_ctx.render();

        // Get drawable
        const drawable_ptr = c.metal_layer_get_next_drawable(ctx.layer);
        if (drawable_ptr == null) continue;

        const texture_ptr = c.metal_drawable_get_texture(drawable_ptr);
        if (texture_ptr == null) continue;

        var drawable_texture = metal.MetalTexture.initFromPtr(texture_ptr);

        // Create render pass
        var render_pass = metal.MetalRenderPassDescriptor.init();
        defer render_pass.deinit();
        render_pass.setColorTexture(&drawable_texture, 0);
        render_pass.setClearColor(0.0, 0.0, 0.0, 1.0, 0);

        // Create command buffer
        var command_buffer = ctx.queue.createCommandBuffer() catch continue;
        defer command_buffer.deinit();

        // Create render encoder
        var render_encoder = command_buffer.createRenderEncoder(&render_pass) catch continue;
        defer render_encoder.deinit();

        // Layer 1: Background rotating quad with center vertex
        render_encoder.setPipeline(&ctx.pipeline);
        render_encoder.setVertexBuffer(&ctx.vertex_buffer, 0, 0);
        render_encoder.setVertexBytes(@ptrCast(&rotation_angle), @sizeOf(f32), 1);
        render_encoder.setVertexBytes(@ptrCast(&translation), @sizeOf([2]f32), 2);
        render_encoder.drawIndexedPrimitives(.triangle, 12, &ctx.index_buffer, 0);

        // Layer 2: IMGUI
        const imgui_index_count = ctx.imgui_ctx.getIndexCount();
        if (imgui_index_count > 0) {
            render_encoder.setPipeline(&ctx.imgui_pipeline);

            const imgui_vb = ctx.imgui_ctx.getVertexBuffer();
            const imgui_ib = ctx.imgui_ctx.getIndexBuffer();
            render_encoder.setVertexBuffer(imgui_vb, 0, 0);

            const screen_size = [2]f32{ ctx.imgui_ctx.display_width, ctx.imgui_ctx.display_height };
            render_encoder.setVertexBytes(@ptrCast(&screen_size), @sizeOf([2]f32), 1);

            render_encoder.drawIndexedPrimitives(.triangle, imgui_index_count, imgui_ib, 0);
        }

        render_encoder.end();

        command_buffer.present(drawable_ptr);
        command_buffer.commit();
    }
}

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
        .source_rgb_blend_factor = .source_alpha,
        .destination_rgb_blend_factor = .one_minus_source_alpha,
        .source_alpha_blend_factor = .one,
        .destination_alpha_blend_factor = .one_minus_source_alpha,
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

    // Quad vertices with center (5 vertices: center + 4 corners)
    const all_vertices = [_]VertexData{
        .{ .position = .{ 0.0, 0.0 }, .color = .{ 1.0, 1.0, 1.0, 1.0 } }, // center: white
        .{ .position = .{ -0.25, 0.25 }, .color = .{ 1.0, 0.0, 0.0, 1.0 } }, // top-left: red
        .{ .position = .{ 0.25, 0.25 }, .color = .{ 0.0, 0.0, 1.0, 1.0 } }, // top-right: blue
        .{ .position = .{ 0.25, -0.25 }, .color = .{ 1.0, 1.0, 0.0, 1.0 } }, // bottom-right: yellow
        .{ .position = .{ -0.25, -0.25 }, .color = .{ 0.0, 1.0, 0.0, 1.0 } }, // bottom-left: green
    };

    // Indices for 4 triangles (each triangle shares the center vertex)
    const quad_indices = [_]u16{
        0, 1, 2, // center, top-left, top-right
        0, 2, 3, // center, top-right, bottom-right
        0, 3, 4, // center, bottom-right, bottom-left
        0, 4, 1, // center, bottom-left, top-left
    };

    const vertex_data_bytes = std.mem.sliceAsBytes(&all_vertices);
    var vertex_buffer = try device.createBuffer(@intCast(vertex_data_bytes.len));
    defer vertex_buffer.deinit();
    vertex_buffer.upload(vertex_data_bytes);

    const index_data_bytes = std.mem.sliceAsBytes(&quad_indices);
    var index_buffer = try device.createBuffer(@intCast(index_data_bytes.len));
    defer index_buffer.deinit();
    index_buffer.upload(index_data_bytes);

    std.debug.print("✓ Created vertex buffer ({} bytes, {} vertices)\n", .{ vertex_data_bytes.len, all_vertices.len });
    std.debug.print("✓ Created index buffer ({} bytes, {} indices)\n", .{ index_data_bytes.len, quad_indices.len });

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

    // Create CVDisplayLink for vsync
    const displaylink = c.metal_displaylink_create(window);
    if (displaylink == null) {
        std.debug.print("Failed to create CVDisplayLink\n", .{});
        return error.DisplayLinkCreationFailed;
    }
    defer c.metal_displaylink_release(displaylink);

    // Set callback and start
    c.metal_displaylink_set_callback(displaylink, displayLinkCallback, null);
    c.metal_displaylink_start(displaylink);
    std.debug.print("✓ Created CVDisplayLink (vsync enabled)\n", .{});

    std.debug.print("🌀 Starting render thread...\n", .{});
    std.debug.print("Close the window or press Cmd+Q to quit.\n\n", .{});

    const start_time = try std.time.Instant.now();

    // Create render context
    var render_ctx = RenderContext{
        .window = window.?,
        .layer = layer.?,
        .queue = queue,
        .pipeline = pipeline,
        .imgui_pipeline = imgui_pipeline,
        .vertex_buffer = vertex_buffer,
        .index_buffer = index_buffer,
        .imgui_ctx = &imgui_ctx,
        .displaylink = displaylink,
        .start_time = start_time,
    };

    // Spawn render thread
    const thread = try std.Thread.spawn(.{}, renderThread, .{&render_ctx});
    thread.detach();

    // Run NSApplication runloop forever (this never returns)
    c.metal_window_run_app();

    // Code below never executes (runloop runs forever)
    unreachable;
}
