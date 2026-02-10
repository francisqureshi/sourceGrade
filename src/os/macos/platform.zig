const std = @import("std");
const App = @import("../../app.zig").App;

const renderer = @import("../../gpu/renderer.zig");

// C bridge for Swift window
const c = @cImport({
    @cInclude("metal_window.h");
});

pub const Platform = struct {
    // Platform state (window, renderer, etc.)
    app: *App,
    render_result: renderer.InitResult,

    pub fn init(app: *App) !Platform {
        // Create window, Metal device, pipelines, CVDisplayLink
        const render_result = try renderer.initRenderContext(app.allocator, app.io, app.config);

        return .{
            .app = app,
            .render_result = render_result,
        };
    }

    /// Start the CVDisplayLink vsync callback. Must be called after init()
    /// when the Platform struct is in its final memory location.
    pub fn startDisplayLink(self: *Platform) void {
        const displaylink = self.render_result.context.displaylink orelse return;

        const ctx_ptr = &self.render_result.context;

        // Set callback with pointer to our stable RenderContext
        c.metal_displaylink_set_callback(
            displaylink,
            renderer.displayLinkCallback,
            @ptrCast(ctx_ptr),
        );
        // Dispatch to main thread for rendering
        c.metal_displaylink_set_dispatch_to_main(displaylink, true);
        c.metal_displaylink_start(displaylink);

        std.debug.print("✓ Started CVDisplayLink\n", .{});
    }

    pub fn deinit(self: *Platform) void {
        // Cleanup
        defer renderer.deinitRenderContext(self.app.allocator, &self.render_result);
    }

    pub fn run(self: *Platform) void {
        _ = self;

        // Run NSApplication event loop
        renderer.runEventLoop();
    }
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

