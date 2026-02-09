const std = @import("std");
const metal = @import("metal");
const ui = @import("../gui/ui.zig");

const media = @import("../io/media.zig");
const videotoolbox = @import("../io/decode/videotoolbox.zig");

const vm = @import("video_monitor.zig");

// C bridge for Swift window
const c = @cImport({
    @cInclude("metal_window.h");
});

// ============================================================================
// Frame Rendering (called from CVDisplayLink via main thread dispatch)
// ============================================================================

/// Called every vsync from the main thread (dispatched by CVDisplayLink).
/// Renders one frame.
pub export fn displayLinkCallback(userdata: ?*anyopaque) callconv(.c) void {
    const ctx: *RenderContext = @ptrCast(@alignCast(userdata orelse return));
    renderFrame(ctx);
}

/// Render state that persists across frames (initialized lazily on first frame)
/// Heap-allocated to ensure stable pointer for VideoMonitor internals
var render_state: ?*RenderState = null;

const RenderState = struct {
    source_media: *media.SourceMedia,
    video_monitor: vm.VideoMonitor,
    test_slider_value: f32 = 0.5,
    ui_frame: u64 = 0,
};

fn renderFrame(ctx: *RenderContext) void {
    // Lazy init of video on first frame
    if (render_state == null) {
        const video_path = ctx.video_path orelse {
            std.debug.print("Error: No video path specified\n", .{});
            return;
        };

        const sm = media.SourceMedia.init(video_path, ctx.io, ctx.allocator) catch |err| {
            std.debug.print("Error: Failed to load video file ({})\n", .{err});
            return;
        };

        var source_media = ctx.allocator.create(media.SourceMedia) catch {
            std.debug.print("Error: Failed to allocate source media\n", .{});
            return;
        };
        source_media.* = sm;

        // Heap-allocate the RenderState so pointers within VideoMonitor remain stable
        const state = ctx.allocator.create(RenderState) catch {
            std.debug.print("Error: Failed to allocate render state\n", .{});
            source_media.deinit();
            ctx.allocator.destroy(source_media);
            return;
        };

        const video_monitor = vm.VideoMonitor.init(ctx, source_media, ctx.allocator) catch |err| {
            std.debug.print("Error: Failed to create video monitor ({})\n", .{err});
            source_media.deinit();
            ctx.allocator.destroy(source_media);
            ctx.allocator.destroy(state);
            return;
        };

        std.debug.print("✓ Loaded video: {d}x{d} @ {d:.2}fps, {d} frames\n\n", .{
            source_media.resolution.width,
            source_media.resolution.height,
            source_media.frame_rate_float,
            source_media.duration_in_frames,
        });

        state.* = .{
            .source_media = source_media,
            .video_monitor = video_monitor,
        };
        render_state = state;
    }

    const state = render_state orelse return;
    state.ui_frame += 1;

    // ============ Get drawable and render
    const drawable_ptr = c.metal_layer_get_next_drawable(ctx.layer);
    if (drawable_ptr == null) return;

    const texture_ptr = c.metal_drawable_get_texture(drawable_ptr);
    if (texture_ptr == null) return;

    var drawable_texture = metal.MetalTexture.initFromPtr(texture_ptr);

    const drawable_width = drawable_texture.getWidth();
    const drawable_height = drawable_texture.getHeight();

    const backing_scale = c.metal_window_get_backing_scale(ctx.window);
    ctx.imgui_ctx.backing_scale_factor = @floatCast(backing_scale);

    const display_width_pts = @as(f32, @floatFromInt(drawable_width)) / @as(f32, @floatCast(backing_scale));
    const display_height_pts = @as(f32, @floatFromInt(drawable_height)) / @as(f32, @floatCast(backing_scale));
    ctx.imgui_ctx.display_width = display_width_pts;
    ctx.imgui_ctx.display_height = display_height_pts;

    var render_pass = metal.MetalRenderPassDescriptor.init();
    defer render_pass.deinit();
    render_pass.setColorTexture(&drawable_texture, 0);
    render_pass.setClearColor(0.0, 0.0, 0.0, 1.0, 0);

    var command_buffer = ctx.queue.createCommandBuffer() catch return;
    defer command_buffer.deinit();

    var render_encoder = command_buffer.createRenderEncoder(&render_pass) catch return;
    defer render_encoder.deinit();

    // ============ Build IMGUI frame
    ctx.imgui_ctx.newFrame();

    // Get mouse input
    var mouse_x: f32 = 0;
    var mouse_y: f32 = 0;
    var mouse_down: bool = false;
    c.metal_window_get_mouse_state(ctx.window, &mouse_x, &mouse_y, &mouse_down);

    ctx.imgui_ctx.mouse_x = mouse_x;
    ctx.imgui_ctx.mouse_y = mouse_y;
    ctx.imgui_ctx.mouse_down = mouse_down;

    // Test slider and rects
    ctx.imgui_ctx.slider(1, 1400, 300, 100, 50, &state.test_slider_value, 0, 1) catch {};
    ctx.imgui_ctx.addRect(1400, 50, 100, 100, ui.ImGuiContext.packColor(state.test_slider_value, 1, 0, 1.0)) catch {};
    ctx.imgui_ctx.addRect(1450, 100, 100, 100, ui.ImGuiContext.packColor(0, 0, 1, 1.0)) catch {};

    // ============ Video Controls
    ctx.imgui_ctx.slider(2, 600, 800, 400, 10, &state.video_monitor.ctrl_playback_speed, 0, 32) catch {};

    const fwd_button_text: []const u8 = if (state.video_monitor.ctrl_playback != 0.0) "pause" else "play >";
    const rev_button_text: []const u8 = if (state.video_monitor.ctrl_playback != 0.0) "pause" else "< play";

    const rev_clicked = ctx.imgui_ctx.button(3, 445, 450, 150, 50, rev_button_text) catch false;
    const fwd_clicked = ctx.imgui_ctx.button(4, 605, 450, 150, 50, fwd_button_text) catch false;

    if (fwd_clicked) {
        if (state.video_monitor.ctrl_playback == 0.0) state.video_monitor.ctrl_playback = 1.0 else state.video_monitor.ctrl_playback = 0.0;
    }

    if (rev_clicked) {
        if (state.video_monitor.ctrl_playback == 0.0) state.video_monitor.ctrl_playback = -1.0 else state.video_monitor.ctrl_playback = 0.0;
    }

    // Frame counter display
    var disp_frame_buf: [1024]u8 = undefined;
    const disp_frame_num = std.fmt.bufPrint(
        &disp_frame_buf,
        "Frame: {d} Playback Speed: {d:.2}",
        .{ state.video_monitor.current_frame_index, state.video_monitor.ctrl_playback_speed },
    ) catch "CantGetFrame";
    _ = ui.ImGuiContext.TextWidget.addText(ctx.imgui_ctx, disp_frame_num, 0, 0, 20.0, .{ 255, 0, 0, 255 }) catch {};

    // ============ LAYOUT DEMO
    // Init HStack
    var row = ui.layout.HStack.init(100, 200, 700, 50, 50);
    const toolbar_height: ui.layout.SizePolicy = .{ .percent = 0.75 };
    row.add(.{ .pixels = 200 }, toolbar_height, 0.1);
    row.add(.{ .pixels = 200 }, toolbar_height, 0.25);
    row.add(.{ .pixels = 200 }, toolbar_height, 0.5);
    row.add(.{ .pixels = 200 }, toolbar_height, 1.0);
    row.solve();

    const btn1_rect = row.get(0);
    const scrub_rect = row.get(1);
    const tc_rect = row.get(2);
    const second_fill_rect = row.get(3);

    // Draw HStack bounding box (red)
    ctx.imgui_ctx.addRect(row.x, row.y, row.w, row.h, ui.ImGuiContext.packColor(1, 0, 0, 1)) catch {};

    // Draw buttons using computed positions
    _ = ctx.imgui_ctx.button(5, btn1_rect.x, btn1_rect.y, btn1_rect.w, btn1_rect.h, "|>") catch false;
    _ = ctx.imgui_ctx.button(6, scrub_rect.x, scrub_rect.y, scrub_rect.w, scrub_rect.h, "------------|-------") catch false;
    _ = ctx.imgui_ctx.button(7, tc_rect.x, tc_rect.y, tc_rect.w, tc_rect.h, "TC 00:00:00:00") catch false;
    _ = ctx.imgui_ctx.button(8, second_fill_rect.x, second_fill_rect.y, second_fill_rect.w, second_fill_rect.h, "Second fill") catch false;

    // Init VStack
    var col = ui.layout.VStack.init(300, 50, 50, 500, 3);
    const vert_bar_width: ui.layout.SizePolicy = .{ .percent = 0.66 };

    col.add(vert_bar_width, .{ .percent = 0.33 }, 1.0);
    for (0..30) |_| {
        col.add(vert_bar_width, .{ .fill = 0.10 }, 0.0);
    }
    col.solve();

    // Draw VStack bounding box (black)
    ctx.imgui_ctx.addRect(col.x, col.y, col.w, col.h, ui.ImGuiContext.packColor(0, 0, 0, 1.0)) catch {};

    // Draw VStack elements
    for (0..col.child_count) |i| {
        const elem = col.get(i);
        ctx.imgui_ctx.addRect(
            elem.x,
            elem.y,
            elem.w,
            elem.h,
            ui.ImGuiContext.packColor(1, 1, 1, (1 / @as(f32, @floatFromInt(i + 1)))),
        ) catch {};
    }

    // Video monitor - decode and manage playback
    _ = state.video_monitor.monitor();

    // Layer 1: Video
    if (state.video_monitor.packed_metal_texture) |*texture| {
        const VideoUniforms = extern struct {
            video_size: [2]f32,
            viewport_size: [2]f32,
        };

        const video_uniforms = VideoUniforms{
            .video_size = .{
                @floatFromInt(state.source_media.resolution.width),
                @floatFromInt(state.source_media.resolution.height),
            },
            .viewport_size = .{ display_width_pts, display_height_pts },
        };

        render_encoder.setPipeline(&ctx.video_pipeline);
        render_encoder.setVertexBytes(@ptrCast(&video_uniforms), @sizeOf(VideoUniforms), 0);
        render_encoder.setFragmentTexture(texture, 0);
        render_encoder.drawPrimitives(.triangle_strip, 0, 4);
    }

    // Layer 2: IMGUI
    ctx.imgui_ctx.render();

    const imgui_index_count = ctx.imgui_ctx.getIndexCount();
    if (imgui_index_count > 0) {
        render_encoder.setPipeline(&ctx.imgui_pipeline);

        const imgui_vb = ctx.imgui_ctx.getVertexBuffer();
        const imgui_ib = ctx.imgui_ctx.getIndexBuffer();
        render_encoder.setVertexBuffer(imgui_vb, 0, 0);

        const ImGuiUniforms = extern struct {
            screen_size: [2]f32,
            use_display_p3: bool,
        };
        const imgui_uniforms = ImGuiUniforms{
            .screen_size = .{ ctx.imgui_ctx.display_width, ctx.imgui_ctx.display_height },
            .use_display_p3 = ctx.config.use_display_p3,
        };
        render_encoder.setVertexBytes(@ptrCast(&imgui_uniforms), @sizeOf(ImGuiUniforms), 1);

        render_encoder.setFragmentTexture(&ctx.imgui_ctx.atlas_texture, 0);
        render_encoder.drawIndexedPrimitives(.triangle, imgui_index_count, imgui_ib, 0);
    }

    render_encoder.end();

    command_buffer.present(drawable_ptr);
    command_buffer.commit();

    c.metal_drawable_release(drawable_ptr);
    c.metal_texture_release(texture_ptr);
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
    imgui_ctx: *ui.ImGuiContext,
    displaylink: ?*anyopaque,
    start_time: std.Io.Clock.Timestamp,

    device_ptr: *anyopaque,
    config: RenderConfig,
    allocator: std.mem.Allocator,
    io: std.Io,
    video_path: ?[]const u8,
};

// ============================================================================
// Initialization
// ============================================================================

pub const InitResult = struct {
    context: RenderContext,
    device: metal.MetalDevice,
    imgui_ctx_owned: *ui.ImGuiContext,
};

/// Initialize all GPU resources. Returns context, device, and heap-allocated imgui context.
/// Caller is responsible for cleanup via deinitRenderContext.
pub fn initRenderContext(
    allocator: std.mem.Allocator,
    io: std.Io,
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
    const imgui_ctx_owned = try allocator.create(ui.ImGuiContext);
    imgui_ctx_owned.* = try ui.ImGuiContext.init(allocator, &device, pixel_format);
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

    std.debug.print("✓ Created CVDisplayLink\n", .{});
    std.debug.print("Close the window or press Cmd+Q to quit.\n\n", .{});

    const start_time = std.Io.Clock.Timestamp.now(io, .awake);

    // Video path to load (loaded lazily on first frame)
    // const video_path = "/Users/mac10/Desktop/A_0005C014_251204_170032_p1CMW_S01.mov";
    const video_path = "/Users/fq/Desktop/AGMM/A_0005C014_251204_170032_p1CMW_S01.mov";
    // const video_path = "/Users/fq/Desktop/AGMM/COS_AW25_4K_4444_LR001_LOG_S06.mov";
    // const video_path = "/Users/fq/Desktop/AGMM/GreyRedHalf.mov";
    // const video_path = "/Users/fq/Desktop/AGMM/GreyRedHalfAlpha.mov";
    // const video_path = "/Users/fq/Desktop/AGMM/A004C002_250326_RQ2M_S01.mov";
    // const video_path = "/Users/fq/Desktop/AGMM/ProRes444_with_Alpha.mov";

    // Create render context
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
        .io = io,
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
// Event Loop
// ============================================================================

pub fn runEventLoop() void {
    // Run NSApplication runloop forever (this never returns)
    c.metal_window_run_app();
}
