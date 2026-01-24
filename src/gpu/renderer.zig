const std = @import("std");
const metal = @import("metal");
const imgui = @import("../gui/imgui.zig");

const media = @import("../io/media.zig");
const vtb = @import("../io/decode/vtb_decode.zig");

// C bridge for Swift window
const c = @cImport({
    @cInclude("metal_window.h");
});

// ============================================================================
// Synchronization
// ============================================================================

pub var frame_semaphore = std.Thread.Semaphore{};

pub export fn displayLinkCallback(_: ?*anyopaque) callconv(.c) void {
    frame_semaphore.post();
}

// ============================================================================
// Configuration & State
// ============================================================================

pub const RenderConfig = struct {
    use_display_p3: bool = true,
    use_10bit: bool = true,
};

pub const RenderContext = struct {
    window: *anyopaque,
    layer: *anyopaque,
    queue: metal.MetalCommandQueue,
    pipeline: metal.MetalRenderPipelineState,
    imgui_pipeline: metal.MetalRenderPipelineState,
    video_pipeline: metal.MetalRenderPipelineState,
    imgui_ctx: *imgui.ImGuiContext,
    displaylink: ?*anyopaque,
    start_time: std.time.Instant,

    device_ptr: *anyopaque,
    config: RenderConfig,
    allocator: std.mem.Allocator,
    video_path: ?[]const u8,
};

// ============================================================================
// Initialization
// ============================================================================

pub const InitResult = struct {
    context: RenderContext,
    device: metal.MetalDevice,
    imgui_ctx_owned: *imgui.ImGuiContext,
};

/// Initialize all GPU resources. Returns context, device, and heap-allocated imgui context.
/// Caller is responsible for cleanup via deinitRenderContext.
pub fn initRenderContext(
    allocator: std.mem.Allocator,
    config: RenderConfig,
) !InitResult {
    // Check if Metal is available
    if (!metal.isAvailable()) {
        std.debug.print("Error: Metal is not available on this system\n", .{});
        return error.MetalNotAvailable;
    }

    // Determine pixel format based on configuration
    const pixel_format: metal.PixelFormat = if (config.use_10bit)
        .rgb10a2_unorm // 10-bit RGB + 2-bit alpha
    else
        .bgra8_unorm; // Standard 8-bit

    std.debug.print("✓ Using pixel format: {s}, Display P3: {}\n", .{
        if (config.use_10bit) "rgb10a2_unorm (10-bit)" else "bgra8_unorm (8-bit)",
        config.use_display_p3,
    });

    // Create window (1600x900, normal window with title bar)
    const window = c.metal_window_create(1600, 900, false);
    if (window == null) {
        std.debug.print("Failed to create window\n", .{});
        return error.WindowCreationFailed;
    }

    std.debug.print("✓ Created Metal window\n", .{});

    // Get the CAMetalLayer from the window
    const layer = c.metal_window_get_layer(window);
    if (layer == null) {
        std.debug.print("Failed to get Metal layer\n", .{});
        c.metal_window_release(window);
        return error.LayerNotFound;
    }

    // Set the layer's pixel format to match our pipelines
    c.metal_layer_set_pixel_format(layer, @intFromEnum(pixel_format));

    std.debug.print("✓ Got CAMetalLayer from window\n", .{});

    // Get the MTLDevice
    const device_ptr = c.metal_window_get_device(window);
    if (device_ptr == null) {
        std.debug.print("Failed to get Metal device\n", .{});
        c.metal_window_release(window);
        return error.DeviceNotFound;
    }

    std.debug.print("✓ Got MTLDevice\n", .{});

    // Create Metal device wrapper from the existing device
    var device = try metal.MetalDevice.init();

    // Create command queue
    const queue = try device.createCommandQueue();
    std.debug.print("✓ Created command queue\n", .{});

    // Load shaders (concatenate UI and video shader files)
    const shader_source = @embedFile("../Shaders.metal") ++ @embedFile("../VideoShaders.metal");

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

    const pipeline = try vertex_fn.createRenderPipeline(&device, &fragment_fn, pipeline_desc);
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

    const imgui_pipeline = try imgui_vertex_fn.createRenderPipeline(&device, &imgui_fragment_fn, imgui_pipeline_desc);
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

    const video_pipeline = try video_vertex_fn.createRenderPipeline(&device, &video_fragment_fn, video_pipeline_desc);
    std.debug.print("✓ Created video render pipeline\n\n", .{});

    // Initialize IMGUI context on heap so pointer stays valid
    const imgui_ctx_owned = try allocator.create(imgui.ImGuiContext);
    imgui_ctx_owned.* = try imgui.ImGuiContext.init(allocator, &device, pixel_format);
    imgui_ctx_owned.display_width = 1600;
    imgui_ctx_owned.display_height = 900;
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

    // Set callback and start
    c.metal_displaylink_set_callback(displaylink, displayLinkCallback, null);
    c.metal_displaylink_start(displaylink);
    std.debug.print("✓ Created CVDisplayLink (vsync enabled)\n", .{});

    std.debug.print("🌀 Starting render thread...\n", .{});
    std.debug.print("Close the window or press Cmd+Q to quit.\n\n", .{});

    const start_time = try std.time.Instant.now();

    // Video path to load (will be loaded in render thread for proper I/O threading)
    // const video_path = "/Users/mac10/Desktop/A_0005C014_251204_170032_p1CMW_S01.mov";
    const video_path = "/Users/fq/Desktop/AGMM/A_0005C014_251204_170032_p1CMW_S01.mov";
    // const video_path = "/Users/fq/Desktop/AGMM/COS_AW25_4K_4444_LR001_LOG_S06.mov";
    // const video_path = "/Users/fq/Desktop/AGMM/GreyRedHalf.mov";
    // const video_path = "/Users/fq/Desktop/AGMM/GreyRedHalfAlpha.mov";
    // const video_path = "/Users/fq/Desktop/AGMM/A004C002_250326_RQ2M_S01.mov";
    // const video_path = "/Users/fq/Desktop/AGMM/ProRes444_with_Alpha.mov";

    // Create render context (video loading deferred to render thread)
    const render_ctx = RenderContext{
        .window = window.?,
        .layer = layer.?,
        .queue = queue,
        .pipeline = pipeline,
        .imgui_pipeline = imgui_pipeline,
        .video_pipeline = video_pipeline,
        .imgui_ctx = imgui_ctx_owned,
        .displaylink = displaylink,
        .start_time = start_time,
        .device_ptr = device_ptr.?,
        .config = config,
        .allocator = allocator,
        .video_path = video_path,
    };

    return InitResult{
        .context = render_ctx,
        .device = device,
        .imgui_ctx_owned = imgui_ctx_owned,
    };
}

pub fn deinitRenderContext(allocator: std.mem.Allocator, result: *InitResult) void {
    result.context.queue.deinit();
    result.context.pipeline.deinit();
    result.context.imgui_pipeline.deinit();
    result.context.video_pipeline.deinit();
    result.imgui_ctx_owned.deinit();
    allocator.destroy(result.imgui_ctx_owned);

    if (result.context.displaylink) |dl| {
        c.metal_displaylink_release(dl);
    }
    c.metal_window_release(result.context.window);
    result.device.deinit();
}

// ============================================================================
// Render Loop
// ============================================================================

/// Main render thread entry point. Runs until terminated.
pub fn renderThread(ctx: *RenderContext) void {
    var slider_value: f32 = 0.5;
    var playback_speed: f32 = 1.0; // 1.0 = normal speed, 0.5 = half speed, 2.0 = double speed
    var is_playing: bool = false;
    var playback_time_ns: u64 = 0;
    // var last_wall_time_ns: u64 = 0;
    var timer = std.time.Timer.start() catch return;

    // Initialize I/O in render thread (CRITICAL: I/O must be initialized on the thread that uses it)
    var threaded = std.Io.Threaded.init(ctx.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Load video in render thread
    var video_fps: f64 = 0;
    var source_media: ?*media.SourceMedia = null;

    // FIXME : Messy is this 'RenderThread' really a qausi-player ? We need a dedicated place for the import and allocatoion on SourceMedias
    if (ctx.video_path) |video_path| {
        if (media.SourceMedia.init(video_path, io, ctx.allocator)) |sm| {
            source_media = ctx.allocator.create(media.SourceMedia) catch null;
            if (source_media) |ptr| {
                ptr.* = sm;
                video_fps = @as(f64, @floatFromInt(sm.frame_rate.get().num)) / @as(f64, @floatFromInt(sm.frame_rate.get().den));
                std.debug.print("✓ Loaded video: {d}x{d} @ {d:.2}fps, {d} frames\n\n", .{
                    sm.resolution.width,
                    sm.resolution.height,
                    video_fps,
                    sm.duration_in_frames,
                });
            }
        } else |err| {
            std.debug.print("Warning: Failed to load video file ({})\n", .{err});
        }
    }
    defer if (source_media) |sm| {
        sm.deinit();
        ctx.allocator.destroy(sm);
    };

    var ui_frame: u64 = 0;
    const base_frame_duration_ns = if (video_fps > 0) @as(u64, @intFromFloat(std.time.ns_per_s / video_fps)) else 0;
    var last_frame_time: u64 = 0;
    var current_frame_index: usize = 0;
    var last_decoded_frame_index: ?usize = null;

    // CRITICAL: Video texture holders must persist across frames!
    // These keep the CVPixelBuffer and Metal textures alive between decode and present
    // For y416 packed format, we use a single RGBA16 texture
    var packed_metal_texture: ?metal.MetalTexture = null;
    var decoded_frame_holder: ?vtb.DecodedFrame = null;
    var texture_set_holder: ?vtb.MetalTextureSet = null;

    while (true) : (ui_frame += 1) {
        // Clean up PREVIOUS frame's resources (from last iteration)
        // This happens BEFORE we start working on the new frame
        if (decoded_frame_holder) |*df| {
            df.deinit();
            decoded_frame_holder = null;
        }
        if (texture_set_holder) |*ts| {
            ts.deinit();
            texture_set_holder = null;
        }

        // Wait for vsync signal from CVDisplayLink
        frame_semaphore.wait();

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

        ctx.imgui_ctx.slider(1, 1400, 300, 100, 50, &slider_value, 0, 1) catch {};
        ctx.imgui_ctx.addRect(1400, 50, 100, 100, imgui.ImGuiContext.packColor(slider_value, 1, 0, 1.0)) catch {};
        ctx.imgui_ctx.addRect(1450, 100, 100, 100, imgui.ImGuiContext.packColor(0, 0, 1, 1.0)) catch {};
        ctx.imgui_ctx.slider(2, 600, 800, 400, 10, &playback_speed, 0, 2) catch {};

        const button_text: []const u8 = if (is_playing) "pause" else "play";

        const clicked = ctx.imgui_ctx.button(3, 600, 450, 200, 50, button_text) catch false;

        if (clicked) {
            is_playing = !is_playing;
            std.debug.print("is_playing: {}\n", .{is_playing});
        }

        // // Add text using new unified system
        // ctx.imgui_ctx.addText("Large-196pt", 50, 200, 196.0, .{ 255, 255, 255, 255 }) catch {};
        // ctx.imgui_ctx.addText("Medium-48pt", 50, 300, 48.0, .{ 200, 200, 255, 255 }) catch {};
        // ctx.imgui_ctx.addText("Small-24pt", 50, 400, 24.0, .{ 255, 200, 200, 255 }) catch {};

        // ============= Video Player

        const ui_frame_delta_ns = timer.lap();
        // on macbook pro with 120 hz this is
        // - ~3ms
        // - ~8.5ms
        // - ~8.5ms
        // - ~10ms
        // - ~11-12ms
        //  About 40ms for 25fps playback but with triple buffered ui vsync of 8.3ms
        //  means 40ms is every 4.8 vsyncs..
        // std.debug.print("frame delta: {}ns\n", .{delta_ns});

        if (is_playing) {
            // Accumulate frame_delta_ns
            playback_time_ns += @as(u64, @intFromFloat(@as(f64, @floatFromInt(ui_frame_delta_ns)) * playback_speed));
        }

        // Video frame timing - decode and create Metal textures from YCbCr
        if (source_media) |sm| {
            const time_since_last_frame = playback_time_ns - last_frame_time;

            // Adjust frame duration by playback speed
            const frame_duration_ns = if (playback_speed > 0.0)
                @as(u64, @intFromFloat(@as(f64, @floatFromInt(base_frame_duration_ns)) / playback_speed))
            else
                base_frame_duration_ns;

            // Should we decode? Yes if:
            // - Frame index changed (first frame, seek, or playback advanced)
            // - OR we're playing and enough time has passed
            const frame_changed = last_decoded_frame_index == null or last_decoded_frame_index.? != current_frame_index;
            const time_to_advance = is_playing and frame_duration_ns > 0 and time_since_last_frame >= frame_duration_ns;
            const should_decode = frame_changed or time_to_advance;

            if (should_decode) {

                // Decode frame from ProRes
                const decoded_frame = sm.decodeSourceFrame(current_frame_index, @ptrCast(ctx.device_ptr)) catch |err| {
                    std.debug.print("❌ Failed to decode frame: {}\n", .{err});
                    continue;
                };
                decoded_frame_holder = decoded_frame; // Keep alive until end of loop

                // Create Metal texture from packed AYUV buffer (y416 format)
                var texture_set = sm.decoder.?.createMetalTextures(decoded_frame.pixel_buffer) catch |err| {
                    std.debug.print("❌ Failed to create Metal textures: {}\n", .{err});
                    continue;
                };
                texture_set_holder = texture_set; // Keep alive until end of loop

                // Extract MTLTexture handle (single packed texture for y416)
                const mtl_tex = texture_set.getMetalTexture();
                packed_metal_texture = metal.MetalTexture.initFromPtr(mtl_tex);

                // Mark this frame as decoded
                last_decoded_frame_index = current_frame_index;

                // Debug: Print actual Metal texture dimensions vs expected
                const State = struct {
                    var printed_texture_debug: bool = false;
                };
                if (!State.printed_texture_debug) {
                    State.printed_texture_debug = true;
                    const tex_width = packed_metal_texture.?.getWidth();
                    const tex_height = packed_metal_texture.?.getHeight();
                    std.debug.print("\nMETAL TEXTURE DEBUG:\n", .{});
                    std.debug.print("   Expected (from source_media): {}x{}\n", .{ sm.resolution.width, sm.resolution.height });
                    std.debug.print("   MTLTexture: {}x{}\n", .{ tex_width, tex_height });
                }

                // Advance to next frame only if playing and time elapsed
                if (time_to_advance) {
                    current_frame_index = (current_frame_index + 1) % @as(usize, @intCast(sm.duration_in_frames));
                    last_frame_time = playback_time_ns;
                }
            }
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

        // Get backing scale factor for HiDPI rendering
        const backing_scale = c.metal_window_get_backing_scale(ctx.window);
        ctx.imgui_ctx.backing_scale_factor = @floatCast(backing_scale);

        // Update IMGUI screen size in POINTS (not pixels)
        const display_width_pts = @as(f32, @floatFromInt(drawable_width)) / @as(f32, @floatCast(backing_scale));
        const display_height_pts = @as(f32, @floatFromInt(drawable_height)) / @as(f32, @floatCast(backing_scale));
        ctx.imgui_ctx.display_width = display_width_pts;
        ctx.imgui_ctx.display_height = display_height_pts;

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

        // Layer 1: Video (packed AYUV y416 format)
        if (packed_metal_texture) |*texture| {
            // Render video frame with YCbCr→RGB conversion in shader
            // Create VideoUniforms for letterboxing (matches Shaders.metal)
            const VideoUniforms = extern struct {
                video_size: [2]f32,
                viewport_size: [2]f32,
            };

            const video_uniforms = VideoUniforms{
                .video_size = .{
                    @floatFromInt(source_media.?.resolution.width),
                    @floatFromInt(source_media.?.resolution.height),
                },
                .viewport_size = .{ display_width_pts, display_height_pts },
            };

            render_encoder.setPipeline(&ctx.video_pipeline);
            render_encoder.setVertexBytes(@ptrCast(&video_uniforms), @sizeOf(VideoUniforms), 0);
            render_encoder.setFragmentTexture(texture, 0); // Packed AYUV texture
            render_encoder.drawPrimitives(.triangle_strip, 0, 4);
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

        render_encoder.end();

        command_buffer.present(drawable_ptr);
        command_buffer.commit();

        // Release retained drawable and texture to prevent memory leaks
        c.metal_drawable_release(drawable_ptr);
        c.metal_texture_release(texture_ptr);
    }
}

pub fn runEventLoop() void {
    // Run NSApplication runloop forever (this never returns)
    c.metal_window_run_app();
}
