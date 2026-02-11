const std = @import("std");
const metal = @import("metal");

const App = @import("../../app.zig").App;
const ui = @import("../../gui/ui.zig");
const media = @import("../../io/media.zig");
const vm = @import("../../gpu/video_monitor.zig");

const Window = @import("window.zig").Window;
const DisplayLink = @import("window.zig").DisplayLink;
const window_helpers = @import("window.zig");
const MetalRenderer = @import("renderer.zig").MetalRenderer;

const gpu_renderer = @import("../../gpu/renderer.zig");

// ============================================================================
// Platform - macOS AppKit + Metal
// ============================================================================

/// macOS platform layer that orchestrates window, renderer, and display link.
/// This is the top-level coordinator for the macOS backend.
/// Owns the render loop via CVDisplayLink callbacks.
pub const Platform = struct {
    /// Reference to the application state (allocator, config, io).
    app: *App,
    /// The macOS window (NSWindow + CAMetalLayer).
    window: Window,
    /// Metal renderer with device, queue, and pipelines.
    renderer: MetalRenderer,
    /// CVDisplayLink for vsync-synchronized rendering.
    displaylink: DisplayLink,
    /// IMGUI context for immediate-mode UI rendering (heap-allocated).
    imgui_ctx: *ui.ImGuiContext,
    /// Render configuration (pixel format, color space settings).
    config: gpu_renderer.RenderConfig,
    /// Timestamp when the platform was initialized (for elapsed time).
    start_time: std.Io.Clock.Timestamp,
    /// Path to video file to load (lazy-loaded on first frame).
    video_path: ?[]const u8,

    /// Initializes the complete macOS platform: window, renderer, IMGUI, and display link.
    /// Does NOT start the display link - call `startDisplayLink()` after init when
    /// the Platform struct is in its final memory location.
    pub fn init(app: *App) !Platform {
        // Check if Metal is available
        if (!metal.isAvailable()) {
            std.debug.print("Error: Metal is not available on this system\n", .{});
            return error.MetalNotAvailable;
        }

        // Create window
        var window = try Window.init(1600, 900, false);

        // Create Metal renderer (device, queue, pipelines)
        var renderer = try MetalRenderer.init(&window, app.config);

        // Initialize IMGUI context on heap so pointer stays valid
        const imgui_ctx = try app.allocator.create(ui.ImGuiContext);
        imgui_ctx.* = try ui.ImGuiContext.init(app.allocator, &renderer.device, renderer.pixel_format);
        imgui_ctx.display_width = 1600;
        imgui_ctx.display_height = 900;
        std.debug.print("✓ Created IMGUI context (triple-buffered)\n\n", .{});

        // Initialize NSApplication (must happen before showing window)
        Window.initApp();

        // Show the window
        window.show();

        // Create CVDisplayLink for vsync
        const displaylink = try DisplayLink.init(&window);

        std.debug.print("Close the window or press Cmd+Q to quit.\n\n", .{});

        const start_time = std.Io.Clock.Timestamp.now(app.io, .awake);

        // Video path to load (loaded lazily on first frame)
        const video_path = "/Users/fq/Desktop/AGMM/A_0005C014_251204_170032_p1CMW_S01.mov";

        return .{
            .app = app,
            .window = window,
            .renderer = renderer,
            .displaylink = displaylink,
            .imgui_ctx = imgui_ctx,
            .config = app.config,
            .start_time = start_time,
            .video_path = video_path,
        };
    }

    /// Start the CVDisplayLink vsync callback. Must be called after init()
    /// when the Platform struct is in its final memory location.
    pub fn startDisplayLink(self: *Platform) void {
        self.displaylink.setCallback(displayLinkCallback, @ptrCast(self));
        self.displaylink.setDispatchToMain(true);
        self.displaylink.start();
        std.debug.print("✓ Started CVDisplayLink\n", .{});
    }

    /// Releases all platform resources in reverse order of creation.
    /// Stops display link, destroys IMGUI context, renderer, and window.
    pub fn deinit(self: *Platform) void {
        self.displaylink.deinit();
        self.imgui_ctx.deinit();
        self.app.allocator.destroy(self.imgui_ctx);
        self.renderer.deinit();
        self.window.deinit();
    }

    /// Runs the macOS event loop. Blocks forever until the app terminates.
    /// All rendering happens via CVDisplayLink callbacks while this runs.
    /// The display link must be started before calling this.
    pub fn run(self: *Platform) void {
        _ = self;
        // Run NSApplication event loop (blocks forever)
        Window.runEventLoop();
    }
};

// ============================================================================
// Frame Rendering (called from CVDisplayLink via main thread dispatch)
// ============================================================================

/// Called every vsync from the main thread (dispatched by CVDisplayLink).
fn displayLinkCallback(userdata: ?*anyopaque) callconv(.c) void {
    const platform: *Platform = @ptrCast(@alignCast(userdata orelse return));
    renderFrame(platform);
}

/// Render state that persists across frames (initialized lazily on first frame).
/// This is a module-level variable because CVDisplayLink callbacks are C functions
/// that can only receive a single userdata pointer (the Platform).
var render_state: ?*RenderState = null;

/// State that persists across render frames.
/// Heap-allocated on first frame and reused for the lifetime of the app.
const RenderState = struct {
    /// The loaded video source (file handle, decoder, metadata).
    source_media: *media.SourceMedia,
    /// Video playback controller (timing, frame index, decode triggers).
    video_monitor: vm.VideoMonitor,
    /// Test slider value for UI demo.
    test_slider_value: f32 = 0.5,
    /// Frame counter for debugging.
    ui_frame: u64 = 0,
};

/// Main render function called every vsync.
/// Handles lazy video initialization, input polling, UI building, and GPU submission.
/// Renders two layers: video (background) and IMGUI (foreground overlay).
fn renderFrame(platform: *Platform) void {
    // Lazy init of video on first frame
    if (render_state == null) {
        const video_path = platform.video_path orelse {
            std.debug.print("Error: No video path specified\n", .{});
            return;
        };

        const sm = media.SourceMedia.init(video_path, platform.app.io, platform.app.allocator) catch |err| {
            std.debug.print("Error: Failed to load video file ({})\n", .{err});
            return;
        };

        var source_media = platform.app.allocator.create(media.SourceMedia) catch {
            std.debug.print("Error: Failed to allocate source media\n", .{});
            return;
        };
        source_media.* = sm;

        const state = platform.app.allocator.create(RenderState) catch {
            std.debug.print("Error: Failed to allocate render state\n", .{});
            source_media.deinit();
            platform.app.allocator.destroy(source_media);
            return;
        };

        const video_monitor = vm.VideoMonitor.init(platform.app.io, platform.window.device_ptr, source_media, platform.app.allocator) catch |err| {
            std.debug.print("Error: Failed to create video monitor ({})\n", .{err});
            source_media.deinit();
            platform.app.allocator.destroy(source_media);
            platform.app.allocator.destroy(state);
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
    const drawable_ptr = platform.window.getNextDrawable() orelse return;
    const texture_ptr = window_helpers.getDrawableTexture(drawable_ptr) orelse return;

    var drawable_texture = metal.MetalTexture.initFromPtr(texture_ptr);

    const drawable_width = drawable_texture.getWidth();
    const drawable_height = drawable_texture.getHeight();

    const backing_scale = platform.window.getBackingScale();
    platform.imgui_ctx.backing_scale_factor = @floatCast(backing_scale);

    const display_width_pts = @as(f32, @floatFromInt(drawable_width)) / @as(f32, @floatCast(backing_scale));
    const display_height_pts = @as(f32, @floatFromInt(drawable_height)) / @as(f32, @floatCast(backing_scale));
    platform.imgui_ctx.display_width = display_width_pts;
    platform.imgui_ctx.display_height = display_height_pts;

    var render_pass = metal.MetalRenderPassDescriptor.init();
    defer render_pass.deinit();
    render_pass.setColorTexture(&drawable_texture, 0);
    render_pass.setClearColor(0.0, 0.0, 0.0, 1.0, 0);

    var command_buffer = platform.renderer.queue.createCommandBuffer() catch return;
    defer command_buffer.deinit();

    var render_encoder = command_buffer.createRenderEncoder(&render_pass) catch return;
    defer render_encoder.deinit();

    // ============ Build IMGUI frame
    platform.imgui_ctx.newFrame();

    // Get mouse input
    var mouse_x: f32 = 0;
    var mouse_y: f32 = 0;
    var mouse_down: bool = false;
    platform.window.getMouseState(&mouse_x, &mouse_y, &mouse_down);

    platform.imgui_ctx.mouse_x = mouse_x;
    platform.imgui_ctx.mouse_y = mouse_y;
    platform.imgui_ctx.mouse_down = mouse_down;

    // Test slider and rects
    platform.imgui_ctx.slider(1, 1400, 300, 100, 50, &state.test_slider_value, 0, 1) catch {};
    platform.imgui_ctx.addRect(1400, 50, 100, 100, ui.ImGuiContext.packColor(state.test_slider_value, 1, 0, 1.0)) catch {};
    platform.imgui_ctx.addRect(1450, 100, 100, 100, ui.ImGuiContext.packColor(0, 0, 1, 1.0)) catch {};

    // ============ Video Controls
    platform.imgui_ctx.slider(2, 600, 800, 400, 10, &state.video_monitor.ctrl_playback_speed, 0, 32) catch {};

    const fwd_button_text: []const u8 = if (state.video_monitor.ctrl_playback != 0.0) "pause" else "play >";
    const rev_button_text: []const u8 = if (state.video_monitor.ctrl_playback != 0.0) "pause" else "< play";

    const rev_clicked = platform.imgui_ctx.button(3, 445, 450, 150, 50, rev_button_text) catch false;
    const fwd_clicked = platform.imgui_ctx.button(4, 605, 450, 150, 50, fwd_button_text) catch false;

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
    _ = ui.ImGuiContext.TextWidget.addText(platform.imgui_ctx, disp_frame_num, 0, 0, 20.0, .{ 255, 0, 0, 255 }) catch {};

    // ============ LAYOUT DEMO
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

    platform.imgui_ctx.addRect(row.x, row.y, row.w, row.h, ui.ImGuiContext.packColor(1, 0, 0, 1)) catch {};

    _ = platform.imgui_ctx.button(5, btn1_rect.x, btn1_rect.y, btn1_rect.w, btn1_rect.h, "|>") catch false;
    _ = platform.imgui_ctx.button(6, scrub_rect.x, scrub_rect.y, scrub_rect.w, scrub_rect.h, "------------|-------") catch false;
    _ = platform.imgui_ctx.button(7, tc_rect.x, tc_rect.y, tc_rect.w, tc_rect.h, "TC 00:00:00:00") catch false;
    _ = platform.imgui_ctx.button(8, second_fill_rect.x, second_fill_rect.y, second_fill_rect.w, second_fill_rect.h, "Second fill") catch false;

    var col = ui.layout.VStack.init(300, 50, 50, 500, 3);
    const vert_bar_width: ui.layout.SizePolicy = .{ .percent = 0.66 };

    col.add(vert_bar_width, .{ .percent = 0.33 }, 1.0);
    for (0..30) |_| {
        col.add(vert_bar_width, .{ .fill = 0.10 }, 0.0);
    }
    col.solve();

    platform.imgui_ctx.addRect(col.x, col.y, col.w, col.h, ui.ImGuiContext.packColor(0, 0, 0, 1.0)) catch {};

    for (0..col.child_count) |i| {
        const elem = col.get(i);
        platform.imgui_ctx.addRect(
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

        render_encoder.setPipeline(&platform.renderer.video_pipeline);
        render_encoder.setVertexBytes(@ptrCast(&video_uniforms), @sizeOf(VideoUniforms), 0);
        render_encoder.setFragmentTexture(texture, 0);
        render_encoder.drawPrimitives(.triangle_strip, 0, 4);
    }

    // Layer 2: IMGUI
    platform.imgui_ctx.render();

    const imgui_index_count = platform.imgui_ctx.getIndexCount();
    if (imgui_index_count > 0) {
        render_encoder.setPipeline(&platform.renderer.imgui_pipeline);

        const imgui_vb = platform.imgui_ctx.getVertexBuffer();
        const imgui_ib = platform.imgui_ctx.getIndexBuffer();
        render_encoder.setVertexBuffer(imgui_vb, 0, 0);

        const ImGuiUniforms = extern struct {
            screen_size: [2]f32,
            use_display_p3: bool,
        };
        const imgui_uniforms = ImGuiUniforms{
            .screen_size = .{ platform.imgui_ctx.display_width, platform.imgui_ctx.display_height },
            .use_display_p3 = platform.config.use_display_p3,
        };
        render_encoder.setVertexBytes(@ptrCast(&imgui_uniforms), @sizeOf(ImGuiUniforms), 1);

        render_encoder.setFragmentTexture(&platform.imgui_ctx.atlas_texture, 0);
        render_encoder.drawIndexedPrimitives(.triangle, imgui_index_count, imgui_ib, 0);
    }

    render_encoder.end();

    command_buffer.present(drawable_ptr);
    command_buffer.commit();

    window_helpers.releaseDrawable(drawable_ptr);
    window_helpers.releaseTexture(texture_ptr);
}
