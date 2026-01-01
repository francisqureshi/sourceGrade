const std = @import("std");
const metal = @import("metal");
const imgui = @import("imgui.zig");
const media = @import("io/media.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

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

// Rendering configuration
const RenderConfig = struct {
    use_display_p3: bool = true, // Enable Display P3 color space
    use_10bit: bool = true, // Enable 10-bit color depth
};

// Render context - all state needed for rendering
const RenderContext = struct {
    window: *anyopaque,
    layer: *anyopaque,
    queue: metal.MetalCommandQueue,
    pipeline: metal.MetalRenderPipelineState,
    imgui_pipeline: metal.MetalRenderPipelineState,
    video_pipeline: metal.MetalRenderPipelineState,
    vertex_buffer: metal.MetalBuffer,
    index_buffer: metal.MetalBuffer,
    imgui_ctx: *imgui.ImGuiContext,
    displaylink: ?*anyopaque,
    start_time: std.time.Instant,
    video_reader: ?*anyopaque,
    device_ptr: *anyopaque,
    video_fps: f64,
    config: RenderConfig,
};

// Render thread entry point
fn renderThread(ctx: *RenderContext) void {
    var frame: u64 = 0;
    // var button_click_count: u32 = 0;
    const speed: f32 = 3000;
    const slider_value: f32 = 0.5;
    // var circle_slider: f32 = 100;
    const playback_speed: f32 = 1.0; // 1.0 = normal speed, 0.5 = half speed, 2.0 = double speed

    // Video frame timing - let CVMetalTextureCache manage texture lifecycle
    const base_frame_duration_ns = if (ctx.video_fps > 0) @as(u64, @intFromFloat(std.time.ns_per_s / ctx.video_fps)) else 0;
    var last_frame_time: u64 = 0;
    var current_video_texture: ?*anyopaque = null;

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
        // if (ctx.imgui_ctx.button(1, 300, 250, 200, 60, "Click Me!") catch false) {
        //     button_click_count += 1;
        //     std.debug.print("Button clicked! Count: {}\n", .{button_click_count});
        // }

        // ctx.imgui_ctx.slider(2, 100, 400, 600, 16, &slider_value, 0.0, 1.0) catch {};
        // ctx.imgui_ctx.slider(3, 100, 450, 600, 16, &speed, 3000, 0.00001) catch {};
        // ctx.imgui_ctx.slider(4, 100, 500, 600, 32, &circle_slider, 0.0, 400) catch {};
        // ctx.imgui_ctx.slider(5, 100, 550, 600, 16, &playback_speed, 0.1, 2.0) catch {}; // Video playback speed

        // Use fullscreen rect (works on Retina too)
        // const full_w = ctx.imgui_ctx.display_width;
        // const full_h = ctx.imgui_ctx.display_height;

        // Draw comparison: 10-bit (top) vs simulated 8-bit (bottom)
        var i: usize = 0;
        while (i < 1024) : (i += 1) {
            const x = 50 + i * 3;
            const brightness = 0.0 + (@as(f32, @floatFromInt(i)) / 1024.0) * 1.0; // 0.3 to 1.0 range

            // Top gradient: Full 10-bit precision (smooth)
            ctx.imgui_ctx.addRect(
                @floatFromInt(x),
                100,
                3,
                200,
                imgui.ImGuiContext.packColor(brightness, brightness, brightness, 1.0),
            ) catch {};
        }

        ctx.imgui_ctx.addRect(1400, 50, 100, 100, imgui.ImGuiContext.packColor(slider_value, 1, 0, 1.0)) catch {};
        ctx.imgui_ctx.addRect(1450, 100, 100, 100, imgui.ImGuiContext.packColor(0, 0, 1, 1.0)) catch {};

        // Add text using new unified system (generates quads in same buffer as shapes)
        ctx.imgui_ctx.addTextNew("Large-96pt", 50, 200, 96.0, .{ 255, 255, 255, 255 }) catch {};
        ctx.imgui_ctx.addTextNew("Medium-48pt", 50, 300, 48.0, .{ 200, 200, 255, 255 }) catch {};
        ctx.imgui_ctx.addTextNew("Small-24pt", 50, 400, 24.0, .{ 255, 200, 200, 255 }) catch {};

        // ctx.imgui_ctx.addRect(0, 0, full_w, full_h, imgui.ImGuiContext.packColor(0.5, 0.5, 0.5, 1.0)) catch {};
        // ctx.imgui_ctx.addTri(100, 50, 0, 100, 100, 100, imgui.ImGuiContext.packColor(0.5, 0.5, 0.5, 1.0)) catch {};
        ctx.imgui_ctx.addCircle(200, 300, 100, 360, imgui.ImGuiContext.packColor(255, 200, 150, 1)) catch {};
        // ctx.imgui_ctx.addCircle(200, 300, circle_slider, 360, imgui.ImGuiContext.packColor(255, 200, 150, 1)) catch {};
        // ctx.imgui_ctx.addLine(0, 599, 800, 599, imgui.ImGuiContext.packColor(1, 0, 0, 1.0), 2.0) catch {};

        // All shapes and text added - render() will be called just before drawing

        // Video frame timing - only advance frame when enough time has elapsed
        var video_texture_ptr: ?*anyopaque = null;
        if (ctx.video_reader) |reader| {
            const time_since_last_frame = elapsed_ns - last_frame_time;

            // Adjust frame duration by playback speed (slower speed = longer duration)
            const frame_duration_ns = if (playback_speed > 0.0)
                @as(u64, @intFromFloat(@as(f64, @floatFromInt(base_frame_duration_ns)) / playback_speed))
            else
                base_frame_duration_ns;

            // Time to advance to next frame?
            if (frame_duration_ns == 0 or time_since_last_frame >= frame_duration_ns) {
                // Get next frame (cache manages texture lifecycle automatically)
                current_video_texture = c.video_reader_get_next_frame(reader);
                if (current_video_texture == null) {
                    // End of video, restart
                    c.video_reader_restart(reader);
                    current_video_texture = c.video_reader_get_next_frame(reader);
                }

                last_frame_time = elapsed_ns;
            }

            video_texture_ptr = current_video_texture;
        }

        // Get drawable
        const drawable_ptr = c.metal_layer_get_next_drawable(ctx.layer);
        if (drawable_ptr == null) continue;

        const texture_ptr = c.metal_drawable_get_texture(drawable_ptr);
        if (texture_ptr == null) continue;

        var drawable_texture = metal.MetalTexture.initFromPtr(texture_ptr);

        // Get actual drawable size (may be 2x on Retina)
        const drawable_width = drawable_texture.getWidth();
        const drawable_height = drawable_texture.getHeight();

        // Update IMGUI screen size with actual drawable dimensions
        ctx.imgui_ctx.display_width = @floatFromInt(drawable_width);
        ctx.imgui_ctx.display_height = @floatFromInt(drawable_height);

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

        // Layer 1: Video or rotating quad
        if (video_texture_ptr) |vtp| {
            // Render video frame (texture is managed by render thread, don't release here)
            var video_texture = metal.MetalTexture.initFromPtr(vtp);
            render_encoder.setPipeline(&ctx.video_pipeline);
            render_encoder.setFragmentTexture(&video_texture, 0);
            render_encoder.drawPrimitives(.triangle_strip, 0, 4);
        } else {
            // Render rotating quad
            render_encoder.setPipeline(&ctx.pipeline);
            render_encoder.setVertexBuffer(&ctx.vertex_buffer, 0, 0);
            render_encoder.setVertexBytes(@ptrCast(&rotation_angle), @sizeOf(f32), 1);
            render_encoder.setVertexBytes(@ptrCast(&translation), @sizeOf([2]f32), 2);
            render_encoder.drawIndexedPrimitives(.triangle, 12, &ctx.index_buffer, 0);
        }

        // Layer 2: IMGUI (unified shapes + text)
        // Finalize IMGUI vertex/index buffers (upload to GPU)
        ctx.imgui_ctx.render();

        const imgui_index_count = ctx.imgui_ctx.getIndexCount();
        if (imgui_index_count > 0) {
            render_encoder.setPipeline(&ctx.imgui_pipeline);

            const imgui_vb = ctx.imgui_ctx.getVertexBuffer();
            const imgui_ib = ctx.imgui_ctx.getIndexBuffer();
            render_encoder.setVertexBuffer(imgui_vb, 0, 0);

            // IMGUI uniforms (matches ImGuiUniforms in shader)
            const ImGuiUniforms = extern struct {
                screen_size: [2]f32,
                use_display_p3: bool,
            };
            const imgui_uniforms = ImGuiUniforms{
                .screen_size = .{ ctx.imgui_ctx.display_width, ctx.imgui_ctx.display_height },
                .use_display_p3 = ctx.config.use_display_p3,
            };
            render_encoder.setVertexBytes(@ptrCast(&imgui_uniforms), @sizeOf(ImGuiUniforms), 1);

            // Bind atlas texture for text rendering
            render_encoder.setFragmentTexture(&ctx.imgui_ctx.atlas_texture, 0);

            render_encoder.drawIndexedPrimitives(.triangle, imgui_index_count, imgui_ib, 0);
        }

        // Done! Single unified draw call for all shapes and text

        render_encoder.end();

        command_buffer.present(drawable_ptr);
        command_buffer.commit();
    }
}

pub fn testSourceMedia() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    const io = threaded.io();

    var argv = try std.process.argsWithAllocator(allocator);
    defer argv.deinit();

    _ = argv.next();
    const filepath = argv.next() orelse {
        std.debug.print("Usage: mov_parser <file.mov> [-v]\n", .{});
        return error.MissingArgument;
    };

    // Open file - if filepath is already absolute, use it; otherwise resolve it
    const file = if (std.fs.path.isAbsolute(filepath))
        try Io.Dir.openFileAbsolute(io, filepath, .{})
    else blk: {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = std.Io.Dir.cwd();
        const cwd_len = try cwd.realPath(io, &path_buf);
        const abs_path = try std.fmt.bufPrint(path_buf[cwd_len..], "/{s}", .{filepath});
        break :blk try Io.Dir.openFileAbsolute(io, path_buf[0 .. cwd_len + abs_path.len], .{});
    };
    defer file.close(io);

    var out_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try file.realPath(io, &out_buffer);
    std.debug.print("got path from file: {s}\n", .{out_buffer[0..path_len]});

    const mctx = media.MediaContext{ .file = file, .io = io, .allocator = allocator };
    var test_source = try media.SourceMedia.init(mctx);
    defer test_source.deinit(allocator);

    std.debug.print("FileName: {s} \n", .{test_source.file_name});
    std.debug.print("Path: {s}\n", .{test_source.file_path});
    std.debug.print("Resolution: {d}x{d}\n", .{ test_source.resolution.width, test_source.resolution.height });
    std.debug.print("Frame Rate: {d}/{d} = {d:.2} fps\n", .{ test_source.frame_rate.num, test_source.frame_rate.den, test_source.frame_rate_float });
    std.debug.print("Drop Frame: {}\n", .{test_source.drop_frame});
    std.debug.print("Start Source Frame: {d}\n", .{test_source.start_frame_number});
    std.debug.print("End Source Frame: {d}\n", .{test_source.end_frame_number});
    std.debug.print("Duration: {d} frames\n", .{test_source.duration_in_frames});
    std.debug.print("Start Source TC: {s}\n", .{test_source.start_timecode});
    std.debug.print("End   Source TC: {s}\n", .{test_source.end_timecode});

    std.debug.print("frame 0: {any}\n", .{test_source.frames[0]});

    // Test reading a frame
    if (test_source.frames.len > 0) {
        const frame_size = try test_source.getFrameSize(0);
        std.debug.print("\nFirst frame size: {d} bytes\n", .{frame_size});

        const buffer = try allocator.alloc(u8, frame_size);
        defer allocator.free(buffer);

        const bytes_read = try test_source.readFrame(mctx, 0, buffer);
        std.debug.print("Read {d} bytes from frame 0\n", .{bytes_read});
        // std.debug.print("buffer: {any}\n", .{buffer});
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

    // Create rendering configuration
    const render_config = RenderConfig{
        .use_display_p3 = true,
        .use_10bit = true,
    };

    // Determine pixel format based on configuration
    const pixel_format: metal.PixelFormat = if (render_config.use_10bit)
        .rgb10a2_unorm // 10-bit RGB + 2-bit alpha
    else
        .bgra8_unorm; // Standard 8-bit

    std.debug.print("✓ Using pixel format: {s}, Display P3: {}\n", .{
        if (render_config.use_10bit) "rgb10a2_unorm (10-bit)" else "bgra8_unorm (8-bit)",
        render_config.use_display_p3,
    });

    // Create window (1600x900, normal window with title bar)
    const window = c.metal_window_create(1600, 900, false);
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

    // Set the layer's pixel format to match our pipelines
    c.metal_layer_set_pixel_format(layer, @intFromEnum(pixel_format));

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
        .pixel_format = pixel_format,
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
        .pixel_format = pixel_format,
        .blend_enabled = true,
        .source_rgb_blend_factor = .one,
        .source_alpha_blend_factor = .one,
        .destination_rgb_blend_factor = .one_minus_source_alpha,
        .destination_alpha_blend_factor = .one_minus_source_alpha,
    };

    var imgui_pipeline = try imgui_vertex_fn.createRenderPipeline(&device, &imgui_fragment_fn, imgui_pipeline_desc);
    defer imgui_pipeline.deinit();
    std.debug.print("✓ Created IMGUI render pipeline\n", .{});

    // Create video pipeline
    var video_vertex_fn = try library.createFunction("videoVertexShader");
    defer video_vertex_fn.deinit();

    var video_fragment_fn = try library.createFunction("videoFragmentShader");
    defer video_fragment_fn.deinit();

    const video_pipeline_desc = metal.RenderPipelineDescriptor{
        .pixel_format = pixel_format,
        .blend_enabled = false,
    };

    var video_pipeline = try video_vertex_fn.createRenderPipeline(&device, &video_fragment_fn, video_pipeline_desc);
    defer video_pipeline.deinit();
    std.debug.print("✓ Created video render pipeline\n\n", .{});

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
    var imgui_ctx = try imgui.ImGuiContext.init(allocator, &device, pixel_format);
    defer imgui_ctx.deinit();
    imgui_ctx.display_width = 1600;
    imgui_ctx.display_height = 900;
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

    // Create video reader with ProRes file
    // const video_path = "/Users/fq/Desktop/AGMM/COS_AW25_4K_4444_LR001_LOG_S06.mov";
    const video_path = "";
    const video_reader = c.video_reader_create(video_path, device_ptr);
    var video_fps: f64 = 0;
    if (video_reader == null) {
        std.debug.print("Warning: Failed to load video file, falling back to rotating quad\n", .{});
    } else {
        var width: i32 = 0;
        var height: i32 = 0;
        var duration: f64 = 0;
        c.video_reader_get_info(video_reader, &width, &height, &duration, &video_fps);
        std.debug.print("✓ Loaded video: {}x{} @ {d:.2}fps, duration: {d:.2}s\n\n", .{ width, height, video_fps, duration });
    }

    // Create render context
    var render_ctx = RenderContext{
        .window = window.?,
        .layer = layer.?,
        .queue = queue,
        .pipeline = pipeline,
        .imgui_pipeline = imgui_pipeline,
        .video_pipeline = video_pipeline,
        .vertex_buffer = vertex_buffer,
        .index_buffer = index_buffer,
        .imgui_ctx = &imgui_ctx,
        .displaylink = displaylink,
        .start_time = start_time,
        .video_reader = video_reader,
        .device_ptr = device_ptr.?,
        .video_fps = video_fps,
        .config = render_config,
    };

    // Spawn render thread
    const thread = try std.Thread.spawn(.{}, renderThread, .{&render_ctx});
    thread.detach();

    // Test SourceMedia
    try testSourceMedia();

    // Run NSApplication runloop forever (this never returns)
    c.metal_window_run_app();

    // Code below never executes (runloop runs forever)
    unreachable;
}
