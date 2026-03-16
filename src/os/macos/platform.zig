const std = @import("std");

const metal = @import("metal");

const App = @import("../../app.zig").App;
const gpu_renderer = @import("../../gpu/renderer.zig");
const ui = @import("../../gui/ui.zig");
const DisplayLink = @import("window.zig").DisplayLink;
const ImGuiRenderer = @import("ui_renderer.zig").ImGuiRenderer;
const MetalRenderer = @import("renderer.zig").MetalRenderer;
const Render = @import("render_state.zig").Render;
const Window = @import("window.zig").Window;
const window_c = @import("window.zig");

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
    imgui_ctx: *ui.ImGui,
    /// ui renderer
    ui_renderer: ImGuiRenderer,
    /// Render configuration (pixel format, color space settings).
    config: gpu_renderer.RenderConfig,
    /// Render State
    /// Lazily initialized on first frame.
    /// Holds video source, decoder state, and textures.
    render: ?*Render,
    /// Timestamp when the platform was initialized (for elapsed time).
    start_time: std.Io.Clock.Timestamp,

    /// Initializes the complete macOS platform: window, renderer, IMGUI, and display link.
    /// Does NOT start the display link - call `startDisplayLink()` after init when
    /// the Platform struct is in its final memory location.
    pub fn init(app: *App) !Platform {
        // Check if Metal is available
        if (!metal.isAvailable()) {
            std.debug.print("Error: Metal is not available on this system\n", .{});
            return error.MetalNotAvailable;
        }

        // Determine pixel format based on configuration
        const pixel_format: metal.PixelFormat = if (app.rndr_config.use_10bit)
            .rgb10a2_unorm // 10-bit RGB + 2-bit alpha
        else
            .bgra8_unorm; // Standard 8-bit

        // Create window
        var window = try Window.init(1600, 900, false);

        // Set the layer's pixel format to match our pipelines
        window.setLayerPixelFormat(@intFromEnum(pixel_format));

        // Create Metal renderer (device, queue, pipelines)
        var renderer = try MetalRenderer.init(pixel_format);

        // Initialize ImGui context on heap so pointer stays valid
        const imgui_ctx = try app.allocator.create(ui.ImGui);
        imgui_ctx.* = try ui.ImGui.init(app.allocator);

        // FIXME:: use cfg
        imgui_ctx.display_width = 1600;
        imgui_ctx.display_height = 900;
        std.debug.print("✓ Created IMGUI context (triple-buffered)\n\n", .{});

        // Initialize ImGuiRenderer
        const imgui_renderer = try ImGuiRenderer.init(
            &renderer.device,
            imgui_ctx.atlas.size,
        );

        // Initialize NSApplication (must happen before showing window)
        Window.initApp();

        // Show the window
        window.show();

        // Create CVDisplayLink for vsync
        const displaylink = try DisplayLink.init(&window);

        std.debug.print("Close the window or press Cmd+Q to quit.\n\n", .{});

        const start_time = std.Io.Clock.Timestamp.now(app.io, .awake);

        return .{
            .app = app,
            .window = window,
            .renderer = renderer,
            .displaylink = displaylink,
            .imgui_ctx = imgui_ctx,
            .ui_renderer = imgui_renderer,
            .config = app.rndr_config,
            .render = null,
            .start_time = start_time,
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
        self.ui_renderer.deinit();

        if (self.render) |render| {
            render.deinit();
            self.app.allocator.destroy(render.source_media);
            self.app.allocator.destroy(render);
        }

        self.app.allocator.destroy(self.imgui_ctx);
        self.renderer.deinit();
        self.window.deinit();

        std.debug.print("bye!\n", .{});
    }

    /// Runs the macOS event loop. Blocks forever until the app terminates.
    /// Starts the CVDisplayLink and runs the NSApplication event loop.
    /// All rendering happens via CVDisplayLink callbacks.
    pub fn run(self: *Platform) !void {
        self.startDisplayLink();

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
    renderUiFrame(platform) catch {};
}

/// Main render function called every vsync.
/// Handles lazy video initialization, input polling, UI building, and GPU submission.
/// Renders two layers: video (background) and IMGUI (foreground overlay).
fn renderUiFrame(self: *Platform) !void {

    // Get or init Render State
    if (self.render == null) {
        const render = self.app.allocator.create(Render) catch return;
        render.* = Render.init(self) catch |err| {
            std.debug.print("Error: Failed to init render state ({})\n", .{err});
            self.app.allocator.destroy(render);
            return;
        };
        self.render = render;
    }
    const render = self.render orelse return;

    render.ui_frame += 1;

    // ============ Get drawable and render
    const drawable_ptr = self.window.getNextDrawable() orelse return;
    const texture_ptr = window_c.getDrawableTexture(drawable_ptr) orelse return;

    var drawable_texture = metal.MetalTexture.initFromPtr(texture_ptr);

    const drawable_width = drawable_texture.getWidth();
    const drawable_height = drawable_texture.getHeight();

    const backing_scale = self.window.getBackingScale();
    self.imgui_ctx.backing_scale_factor = @floatCast(backing_scale);

    const display_width_pts = @as(f32, @floatFromInt(drawable_width)) / @as(
        f32,
        @floatCast(backing_scale),
    );
    const display_height_pts = @as(f32, @floatFromInt(drawable_height)) / @as(
        f32,
        @floatCast(backing_scale),
    );
    self.imgui_ctx.display_width = display_width_pts;
    self.imgui_ctx.display_height = display_height_pts;

    var render_pass = metal.MetalRenderPassDescriptor.init();
    defer render_pass.deinit();
    render_pass.setColorTexture(&drawable_texture, 0);
    render_pass.setClearColor(0.0, 0.0, 0.0, 1.0, 0);

    var command_buffer = self.renderer.queue.createCommandBuffer() catch return;
    defer command_buffer.deinit();

    var render_encoder = command_buffer.createRenderEncoder(&render_pass) catch return;
    defer render_encoder.deinit();

    // ============ Build IMGUI frame
    self.imgui_ctx.newFrame();

    // Get mouse input
    var mouse_x: f32 = 0;
    var mouse_y: f32 = 0;
    var mouse_down: bool = false;
    self.window.getMouse(&mouse_x, &mouse_y, &mouse_down);

    self.imgui_ctx.mouse_x = mouse_x;
    self.imgui_ctx.mouse_y = mouse_y;
    self.imgui_ctx.mouse_down = mouse_down;

    try self.app.buildUI(self.imgui_ctx, &self.render.?.video_monitor);

    // Decode the frame with Metal
    decodeVideoFrame(render) catch {};

    self.app.playback.current_frame = render.video_monitor.current_frame_index.load(.acquire);

    // Layer 1: Video
    if (render.packed_metal_texture) |*texture| {
        const VideoUniforms = extern struct {
            video_size: [2]f32,
            viewport_size: [2]f32,
        };

        const video_uniforms = VideoUniforms{
            .video_size = .{
                @floatFromInt(render.source_media.resolution.width),
                @floatFromInt(render.source_media.resolution.height),
            },
            .viewport_size = .{ display_width_pts, display_height_pts },
        };

        render_encoder.setPipeline(&self.renderer.video_pipeline);
        render_encoder.setVertexBytes(@ptrCast(&video_uniforms), @sizeOf(VideoUniforms), 0);
        render_encoder.setFragmentTexture(texture, 0);
        render_encoder.drawPrimitives(.triangle_strip, 0, 4);
    }

    // Layer 2: IMGUI
    self.ui_renderer.upload(self.imgui_ctx);

    const imgui_index_count = self.imgui_ctx.getIndexCount();
    if (imgui_index_count > 0) {
        render_encoder.setPipeline(&self.renderer.imgui_pipeline);

        const imgui_vb = self.ui_renderer.getVertexBuffer();
        const imgui_ib = self.ui_renderer.getIndexBuffer();
        render_encoder.setVertexBuffer(imgui_vb, 0, 0);

        const ImGuiUniforms = extern struct {
            screen_size: [2]f32,
            use_display_p3: bool,
        };
        const imgui_uniforms = ImGuiUniforms{
            .screen_size = .{ self.imgui_ctx.display_width, self.imgui_ctx.display_height },
            .use_display_p3 = self.config.use_display_p3,
        };
        render_encoder.setVertexBytes(@ptrCast(&imgui_uniforms), @sizeOf(ImGuiUniforms), 1);

        render_encoder.setFragmentTexture(&self.ui_renderer.atlas_texture, 0);
        render_encoder.drawIndexedPrimitives(.triangle, imgui_index_count, imgui_ib, 0);
    }

    render_encoder.end();

    command_buffer.present(drawable_ptr);
    command_buffer.commit();

    window_c.releaseDrawable(drawable_ptr);
    window_c.releaseTexture(texture_ptr);
}

fn decodeVideoFrame(render: *Render) !void {

    // Read current frame from monitor thread
    const frame_idx = render.video_monitor.current_frame_index.load(.acquire);

    // Only decode if frame changed
    if (render.video_monitor.last_decoded_frame_index == null or
        render.video_monitor.last_decoded_frame_index.? != frame_idx)
    {
        // Reset scratch arena before decode
        _ = render.video_monitor.decode_arena.reset(.free_all);

        // Clean up previous frame resources before next decode
        if (render.decoded_frame_buffer) |*df| {
            df.deinit();
            render.decoded_frame_buffer = null;
        }
        if (render.texture_set_holder) |*ts| {
            ts.deinit();
            render.texture_set_holder = null;
        }

        const decoded_frame = render.decoder.decodeFrame(
            frame_idx,
            render.video_monitor.decode_arena.allocator(),
        ) catch |err| {
            std.debug.print("Failed to decode frame: {}\n", .{err});
            return error.DecodeFrameFailed;
        };
        render.decoded_frame_buffer = decoded_frame; // Keep alive until end of loop

        // Create Metal texture from packed AYUV buffer (y416 format)
        var texture_set = render.decoder.createMetalTextures(
            @ptrCast(decoded_frame.platform_handle),
        ) catch |err| {
            std.debug.print("Failed to create Metal textures: {}\n", .{err});
            return error.TextureCreationFailed;
        };
        render.texture_set_holder = texture_set; // Keep alive until end of loop

        // Extract MTLTexture handle (single packed texture for y416)
        const mtl_tex = texture_set.getMetalTexture();
        render.packed_metal_texture = metal.MetalTexture.initFromPtr(mtl_tex);

        // Mark as decoded WARN: here, not start.
        render.video_monitor.last_decoded_frame_index = frame_idx;
    }
}

// std.debug.print("Decoding frame {} (last={?})\nLast Frame Time: {d}\n", .{
//     frame_info.frame_idx,
//     state.video_monitor.last_decoded_frame_index,
//     state.video_monitor.monitor_stats.time_since_last_frame_ns,
// });

// std.debug.print("Frame Time: #{} | wall: {d:.1}ms | playback delta: {d:.1}ms (expected: {d:.1}ms)\n", .{
//     frame_info.frame_idx,
//     @as(f64, @floatFromInt(state.video_monitor.monitor_stats.wall_clock_delta_ns)) /
//         std.time.ns_per_ms,
//     @as(f64, @floatFromInt(state.video_monitor.monitor_stats.time_since_last_frame_ns)) /
//         std.time.ns_per_ms,
//     @as(f64, @floatFromInt(state.video_monitor.monitor_stats.frame_duration_ns)) / std.time.ns_per_ms,
// });

// std.debug.print("\nFrame info: \nCompressed Size:{d} \nDecompressed Size: {d}\n", .{
//     decoded_frame.compressed_size,
//     decoded_frame.decoded_size,
// });
