const std = @import("std");
const metal = @import("metal");

const log = std.log.scoped(.metal);

// ============================================================================
// Metal Renderer - handles device, queue, shaders, and pipelines
// ============================================================================

/// Metal renderer that manages the GPU device, command queue, and render pipelines.
/// This is macOS-specific and uses the Metal graphics API.
/// Owns three pipelines: main (unused currently), IMGUI (UI overlay), and video (fullscreen video).
pub const MetalRenderer = struct {
    /// The Metal device (GPU) used for all rendering operations.
    device: metal.MetalDevice,
    /// Command queue for submitting render work to the GPU.
    queue: metal.MetalCommandQueue,
    /// Compiled shader library containing all vertex/fragment shaders.
    library: metal.MetalLibrary,
    /// Main render pipeline (currently unused, placeholder for future use).
    pipeline: metal.MetalRenderPipelineState,
    /// IMGUI pipeline with alpha blending for UI overlay rendering.
    imgui_pipeline: metal.MetalRenderPipelineState,
    /// Video pipeline for rendering decoded video frames (no blending).
    video_pipeline: metal.MetalRenderPipelineState,
    /// Pixel format used by all pipelines (must match the CAMetalLayer).
    pixel_format: metal.PixelFormat,

    /// Initializes the Metal renderer with device, queue, shaders, and all pipelines.
    /// Sets the window's layer pixel format to match the configured format.
    /// Creates three pipelines: main, imgui (with alpha blending), and video.
    pub fn init(pixel_format: metal.PixelFormat) !MetalRenderer {
        // Create Metal device wrapper
        var device = try metal.MetalDevice.init();

        // Create command queue
        const queue = try device.createCommandQueue();
        log.debug("✓ Created command queue", .{});

        // Load shaders (concatenate UI and video shader files)
        const shader_source = @embedFile("Shaders.metal") ++ @embedFile("VideoShaders.metal");

        var library = try device.createLibraryFromSource(shader_source);
        log.debug("✓ Compiled shader library", .{});

        // ============ Create main pipeline
        var vertex_fn = try library.createFunction("vertexShaderBuffered");
        defer vertex_fn.deinit();

        var fragment_fn = try library.createFunction("fragmentShader");
        defer fragment_fn.deinit();
        log.debug("✓ Loaded vertex and fragment shaders", .{});

        const pipeline_desc = metal.RenderPipelineDescriptor{
            .pixel_format = pixel_format,
            .blend_enabled = false,
        };

        const pipeline = try vertex_fn.createRenderPipeline(&device, &fragment_fn, pipeline_desc);
        log.debug("✓ Created render pipeline", .{});

        // ============ Create IMGUI pipeline with alpha blending
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
        log.debug("✓ Created IMGUI render pipeline", .{});

        // ============ Create video pipeline
        var video_vertex_fn = try library.createFunction("videoVertexShader");
        defer video_vertex_fn.deinit();

        var video_fragment_fn = try library.createFunction("videoFragmentShader");
        defer video_fragment_fn.deinit();

        const video_pipeline_desc = metal.RenderPipelineDescriptor{
            .pixel_format = pixel_format,
            .blend_enabled = false,
        };

        const video_pipeline = try video_vertex_fn.createRenderPipeline(&device, &video_fragment_fn, video_pipeline_desc);
        log.debug("✓ Created video render pipeline", .{});

        return .{
            .device = device,
            .queue = queue,
            .library = library,
            .pipeline = pipeline,
            .imgui_pipeline = imgui_pipeline,
            .video_pipeline = video_pipeline,
            .pixel_format = pixel_format,
        };
    }

    /// Releases all Metal resources: pipelines, library, queue, and device.
    /// Must be called when the renderer is no longer needed.
    /// Order matters: pipelines first, then library, queue, and finally device.
    pub fn deinit(self: *MetalRenderer) void {
        self.queue.deinit();
        self.pipeline.deinit();
        self.imgui_pipeline.deinit();
        self.video_pipeline.deinit();
        self.library.deinit();
        self.device.deinit();
    }
};
