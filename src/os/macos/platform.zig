const std = @import("std");

const com = @import("com");
const metal = @import("metal");

const App = @import("../../app.zig").App;
const Core = @import("../../core.zig").Core;
const ImGui = @import("../../gui/ui.zig").ImGui;
const DisplayLink = @import("window.zig").DisplayLink;
const ImGuiRenderer = @import("ui_renderer.zig").ImGuiRenderer;
const MetalRenderer = @import("metal_renderer.zig").MetalRenderer;
const FrameDecoder = @import("frame_decoder.zig").FrameDecoder;
const Window = @import("window.zig").Window;
const window_c = @import("window.zig");
const VideoMonitor = @import("../../playback/video_monitor.zig").VideoMonitor;

// ============================================================================
// Platform - macOS AppKit + Metal
// ============================================================================

/// macOS platform layer that orchestrates window, renderer, and display link.
/// This is the top-level coordinator for the macOS backend.
/// Owns the render loop via CVDisplayLink callbacks.
pub const Platform = struct {
    /// Reference to the application state (allocator, config, io).
    app: *App,
    // Ref to Core
    core: *Core,
    /// The macOS window (NSWindow + CAMetalLayer).
    window: Window,
    /// Metal renderer with device, queue, and pipelines.
    metal_renderer: MetalRenderer,
    /// CVDisplayLink for vsync-synchronized rendering.
    displaylink: DisplayLink,
    /// IMGUI context for immediate-mode UI rendering (heap-allocated).
    imgui_ctx: *ImGui,
    /// ui renderer
    ui_renderer: ImGuiRenderer,
    /// Frame decoder - lazily initialized on first frame.
    /// Manages video decoding and GPU texture lifetime.
    frame_decoder: ?*FrameDecoder,
    /// Timestamp when the platform was initialized (for elapsed time).
    start_time: std.Io.Clock.Timestamp,

    /// Initializes the complete macOS platform: window, renderer, IMGUI, and display link.
    pub fn init(app: *App, core: *Core) !Platform {

        // Check if Metal is available
        if (!metal.isAvailable()) {
            std.debug.print("Error: Metal is not available on this system\n", .{});
            return error.MetalNotAvailable;
        }

        // Determine pixel format based on configuration
        const pixel_format: metal.PixelFormat = if (core.cfg.constants.metal_use_10bit)
            .rgb10a2_unorm // 10-bit RGB + 2-bit alpha
        else
            .bgra8_unorm; // Standard 8-bit

        // Parse window dimensions from config
        const width: u32 = switch (core.cfg.window) {
            .maximised => 1920, // Fallback for maximised
            .specific_size => |size| size.width,
        };
        const height: u32 = switch (core.cfg.window) {
            .maximised => 1080,
            .specific_size => |size| size.height,
        };

        // Create window
        var window = try Window.init(@intCast(width), @intCast(height), false);

        // Set the layer's pixel format to match our pipelines
        window.setLayerPixelFormat(@intFromEnum(pixel_format));

        // Create Metal renderer (device, queue, pipelines)
        var metal_renderer = try MetalRenderer.init(pixel_format);

        // Initialize ImGui context on heap so pointer stays valid
        const imgui_ctx = try app.allocator.create(ImGui);
        imgui_ctx.* = try ImGui.init(app.allocator);

        // Set ImGui display size from config
        imgui_ctx.display_width = @floatFromInt(width);
        imgui_ctx.display_height = @floatFromInt(height);
        std.debug.print("✓ Created IMGUI context (triple-buffered)\n\n", .{});

        // Initialize ImGuiRenderer
        const imgui_renderer = try ImGuiRenderer.init(
            &metal_renderer.device,
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
            .core = core,
            .window = window,
            .metal_renderer = metal_renderer,
            .displaylink = displaylink,
            .imgui_ctx = imgui_ctx,
            .ui_renderer = imgui_renderer,
            .frame_decoder = null,
            .start_time = start_time,
        };
    }

    /// Start the CVDisplayLink vsync callback. Must be called after init()
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

        if (self.frame_decoder) |frame_decoder| {
            frame_decoder.deinit();
            self.app.allocator.destroy(frame_decoder);
        }

        self.app.allocator.destroy(self.imgui_ctx);
        self.metal_renderer.deinit();
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

    // Get or init FrameDecoder
    if (self.frame_decoder == null) {
        // Load source media into Core first
        if (self.core.source_media == null) {
            const video_path = self.core.cfg.testing.video_path;
            self.core.loadSourceMedia(video_path) catch |err| {
                std.debug.print("Error: Failed to load source media ({})\n", .{err});
                return;
            };
        }

        // Now create FrameDecoder (uses Core's source_media reference)
        const frame_decoder = self.app.allocator.create(FrameDecoder) catch return;
        frame_decoder.* = FrameDecoder.init(self) catch |err| {
            std.debug.print("Error: Failed to init FrameDecoder ({})\n", .{err});
            self.app.allocator.destroy(frame_decoder);
            return;
        };
        self.frame_decoder = frame_decoder;
    }
    const frame_decoder = self.frame_decoder orelse return;

    frame_decoder.ui_frame += 1;

    //  Get drawable and render
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

    var command_buffer = self.metal_renderer.queue.createCommandBuffer() catch return;
    defer command_buffer.deinit();

    var render_encoder = command_buffer.createRenderEncoder(&render_pass) catch return;
    defer render_encoder.deinit();

    //  Build IMGUI frame
    self.imgui_ctx.newFrame();

    // Get all mouse input (position, buttons, scroll)
    var mouse_x: f32 = 0;
    var mouse_y: f32 = 0;
    var mouse_down: bool = false;
    var mouse_middle_down: bool = false;
    var scroll_x: f32 = 0;
    var scroll_y: f32 = 0;
    self.window.getMouse(
        &mouse_x,
        &mouse_y,
        &mouse_down,
        &mouse_middle_down,
        &scroll_x,
        &scroll_y,
    );

    self.imgui_ctx.mouse_x = mouse_x;
    self.imgui_ctx.mouse_y = mouse_y;
    self.imgui_ctx.mouse_down = mouse_down;

    // TODO: Wire scroll/middle-click to viewer pan/zoom
    // For now, just print when we get input
    if (mouse_middle_down) {
        std.debug.print("Middle mouse down at ({d:.1}, {d:.1})\n", .{ mouse_x, mouse_y });
    }
    if (scroll_y != 0) {
        std.debug.print("Scroll Y: {d:.2}\n", .{scroll_y});
    }

    try self.app.buildUI(self.imgui_ctx);

    // Get first viewer (for now - future: loop through all viewers)
    const source_viewer = &self.app.viewers.items[0];

    // Get the monitor this viewer is displaying
    const monitor_id = source_viewer.monitor_id orelse return; // Skip if no monitor attached
    if (monitor_id >= self.core.video_monitors.items.len) return; // Safety check
    const monitor = &self.core.video_monitors.items[monitor_id];

    // Decode the frame for this viewer's monitor
    decodeVideoFrame(frame_decoder, self.core, monitor) catch {};

    // Layer 1: Video (render into viewer bounds)
    if (frame_decoder.packed_metal_texture) |*texture| {
        const VideoUniforms = extern struct {
            video_size: [2]f32,
            viewport_size: [2]f32,
            viewer_rect: [4]f32, // x, y, width, height
            zoom: f32,
            pan_offset: [2]f32,
        };

        const video_uniforms = VideoUniforms{
            .video_size = .{
                @floatFromInt(frame_decoder.source_media.resolution.width),
                @floatFromInt(frame_decoder.source_media.resolution.height),
            },
            .viewport_size = .{ display_width_pts, display_height_pts },
            .viewer_rect = .{ source_viewer.x, source_viewer.y, source_viewer.width, source_viewer.height },
            .zoom = source_viewer.zoom,
            .pan_offset = .{ source_viewer.pan_x, source_viewer.pan_y },
        };

        render_encoder.setPipeline(&self.metal_renderer.video_pipeline);
        render_encoder.setVertexBytes(@ptrCast(&video_uniforms), @sizeOf(VideoUniforms), 0);
        render_encoder.setFragmentTexture(texture, 0);
        render_encoder.drawPrimitives(.triangle_strip, 0, 4);
    }

    // Layer 2: IMGUI
    self.ui_renderer.upload(self.imgui_ctx);

    const imgui_index_count = self.imgui_ctx.getIndexCount();
    if (imgui_index_count > 0) {
        render_encoder.setPipeline(&self.metal_renderer.imgui_pipeline);

        const imgui_vb = self.ui_renderer.getVertexBuffer();
        const imgui_ib = self.ui_renderer.getIndexBuffer();
        render_encoder.setVertexBuffer(imgui_vb, 0, 0);

        const ImGuiUniforms = extern struct {
            screen_size: [2]f32,
            use_display_p3: bool,
        };
        const imgui_uniforms = ImGuiUniforms{
            .screen_size = .{ self.imgui_ctx.display_width, self.imgui_ctx.display_height },
            .use_display_p3 = self.core.cfg.constants.metal_use_display_p3,
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

fn decodeVideoFrame(frame_decoder: *FrameDecoder, core: *Core, video_monitor: *VideoMonitor) !void {
    _ = core;
    // Get video_monitor from Core
    // const video_monitor = if (core.video_monitor) |*vm| vm else return error.NoVideoMonitor;

    // Read current frame from monitor thread
    const frame_idx = video_monitor.current_frame_index.load(.acquire);

    // Only decode if frame changed
    if (video_monitor.last_decoded_frame_index == null or
        video_monitor.last_decoded_frame_index.? != frame_idx)
    {
        // Reset scratch arena before decode
        _ = video_monitor.decode_arena.reset(.free_all);

        // Clean up previous frame resources before next decode
        if (frame_decoder.decoded_frame_buffer) |*df| {
            df.deinit();
            frame_decoder.decoded_frame_buffer = null;
        }
        if (frame_decoder.texture_set_holder) |*ts| {
            ts.deinit();
            frame_decoder.texture_set_holder = null;
        }

        const decoded_frame = frame_decoder.decoder.decodeFrame(
            frame_idx,
            video_monitor.decode_arena.allocator(),
        ) catch |err| {
            std.debug.print("Failed to decode frame: {}\n", .{err});
            return error.DecodeFrameFailed;
        };
        frame_decoder.decoded_frame_buffer = decoded_frame; // Keep alive until end of loop

        // Create Metal texture from packed AYUV buffer (y416 format)
        var texture_set = frame_decoder.decoder.createMetalTextures(
            @ptrCast(decoded_frame.platform_handle),
        ) catch |err| {
            std.debug.print("Failed to create Metal textures: {}\n", .{err});
            return error.TextureCreationFailed;
        };
        frame_decoder.texture_set_holder = texture_set; // Keep alive until end of loop

        // Extract MTLTexture handle (single packed texture for y416)
        const mtl_tex = texture_set.getMetalTexture();
        frame_decoder.packed_metal_texture = metal.MetalTexture.initFromPtr(mtl_tex);

        // Mark as decoded
        video_monitor.last_decoded_frame_index = frame_idx;
    }
}
