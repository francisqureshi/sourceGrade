//! Main text rendering system using Metal

const TextRenderer = @This();

const std = @import("std");
const metal = @import("metal");
const Atlas = @import("font/Atlas.zig");
const Font = @import("font/Font.zig");
const Glyph = @import("font/Glyph.zig");
const GlyphCache = @import("font/GlyphCache.zig");
const TextVertex = @import("TextVertex.zig");

const Allocator = std.mem.Allocator;

allocator: Allocator,
device: *metal.MetalDevice,
pipeline: metal.MetalRenderPipelineState,
atlas: Atlas,
atlas_texture: metal.MetalTexture,
font: Font,
glyph_cache: GlyphCache,
vertex_buffer: metal.MetalBuffer,
index_buffer: metal.MetalBuffer,
screen_size_buffer: metal.MetalBuffer,
max_vertices: usize,
atlas_modified: usize = 0,

pub fn init(
    allocator: Allocator,
    device: *metal.MetalDevice,
    font_name: [:0]const u8,
    font_size: f32,
    atlas_size: u32,
    max_glyphs: usize,
) !TextRenderer {
    // Create font
    var font = try Font.init(font_name, font_size);
    errdefer font.deinit();

    // Create atlas
    var atlas = try Atlas.init(allocator, atlas_size, .grayscale);
    errdefer atlas.deinit(allocator);

    // Create atlas texture (grayscale R8)
    var atlas_texture = try device.createTextureWithFormat(atlas_size, atlas_size, .r8_unorm, false);
    errdefer atlas_texture.deinit();

    // Create vertex buffer (4 vertices per glyph for quad)
    const max_vertices = max_glyphs * 4;
    var vertex_buffer = try device.createBuffer(@intCast(@sizeOf(TextVertex) * max_vertices));
    errdefer vertex_buffer.deinit();

    // Create index buffer (6 indices per glyph: 2 triangles)
    const max_indices = max_glyphs * 6;
    var index_buffer = try device.createBuffer(@intCast(@sizeOf(u16) * max_indices));
    errdefer index_buffer.deinit();

    // Create screen size buffer
    var screen_size_buffer = try device.createBuffer(@sizeOf([2]f32));
    errdefer screen_size_buffer.deinit();

    // Load shaders
    const shader_source = @embedFile("TextShaders.metal");
    var library = try device.createLibraryFromSource(shader_source);
    defer library.deinit();

    var vertex_fn = try library.createFunction("textVertexShader");
    defer vertex_fn.deinit();

    var fragment_fn = try library.createFunction("textFragmentShader");
    defer fragment_fn.deinit();

    // Create pipeline with alpha blending
    const pipeline_desc = metal.RenderPipelineDescriptor{
        .pixel_format = .bgra8_unorm,
        .blend_enabled = true,
        .source_rgb_blend_factor = .source_alpha,
        .destination_rgb_blend_factor = .one_minus_source_alpha,
        .rgb_blend_operation = .add,
        .source_alpha_blend_factor = .one,
        .destination_alpha_blend_factor = .one_minus_source_alpha,
        .alpha_blend_operation = .add,
    };

    var pipeline = try vertex_fn.createRenderPipeline(device, &fragment_fn, pipeline_desc);
    errdefer pipeline.deinit();

    return .{
        .allocator = allocator,
        .device = device,
        .pipeline = pipeline,
        .atlas = atlas,
        .atlas_texture = atlas_texture,
        .font = font,
        .glyph_cache = GlyphCache.init(),
        .vertex_buffer = vertex_buffer,
        .index_buffer = index_buffer,
        .screen_size_buffer = screen_size_buffer,
        .max_vertices = max_vertices,
    };
}

pub fn deinit(self: *TextRenderer) void {
    self.glyph_cache.deinit(self.allocator);
    self.font.deinit();
    self.atlas.deinit(self.allocator);
    self.atlas_texture.deinit();
    self.vertex_buffer.deinit();
    self.index_buffer.deinit();
    self.screen_size_buffer.deinit();
    self.pipeline.deinit();
}

/// Update screen size for coordinate transformation
pub fn setScreenSize(self: *TextRenderer, width: f32, height: f32) void {
    const screen_size = [2]f32{ width, height };
    self.screen_size_buffer.upload(std.mem.asBytes(&screen_size));
}

/// Render text at the specified position with color
pub fn renderText(
    self: *TextRenderer,
    encoder: *metal.MetalRenderEncoder,
    text: []const u8,
    x: f32,
    y: f32,
    color: [4]u8,
) !void {
    if (text.len == 0) return;

    // Prepare vertices for all glypph quads
    const max_glyphs = self.max_vertices / 4;
    if (text.len > max_glyphs) return error.TextTooLong;

    var vertices = try self.allocator.alloc(TextVertex, text.len * 4);
    defer self.allocator.free(vertices);

    var cursor_x = x;
    var vertex_idx: usize = 0;

    for (text) |char| {
        const codepoint: u21 = char; // Simple ASCII for now

        // Get or create glyph
        const glyph_id = try self.font.getGlyphID(codepoint);
        const glyph = try self.getOrRenderGlyph(glyph_id);

        // Create 4 vertices for this glyph quad
        for (0..4) |i| {
            vertices[vertex_idx + i] = .{
                .glyph_pos = .{ glyph.atlas_x, glyph.atlas_y },
                .glyph_size = .{ glyph.width, glyph.height },
                .bearings = .{ @intCast(glyph.bearing_x), @intCast(glyph.bearing_y) },
                .screen_pos = .{ cursor_x, y },
                .color = color,
            };
        }

        cursor_x += glyph.advance_x;
        vertex_idx += 4;
    }

    // Upload vertices to GPU
    self.vertex_buffer.upload(std.mem.sliceAsBytes(vertices));

    // Generate indices for quads (2 triangles per quad)
    // Each quad: 0,1,2, 0,2,3 where 0=TL, 1=TR, 2=BR, 3=BL
    const glyph_count = vertex_idx / 4;
    const indices = try self.allocator.alloc(u16, glyph_count * 6);
    defer self.allocator.free(indices);

    var idx: usize = 0;
    var i: u32 = 0;
    while (i < glyph_count) : (i += 1) {
        const base: u16 = @intCast(i * 4);
        // Triangle 1: TL, TR, BR
        indices[idx + 0] = base + 0;
        indices[idx + 1] = base + 1;
        indices[idx + 2] = base + 2;
        // Triangle 2: TL, BR, BL
        indices[idx + 3] = base + 0;
        indices[idx + 4] = base + 2;
        indices[idx + 5] = base + 3;
        idx += 6;
    }

    // Upload indices to GPU
    self.index_buffer.upload(std.mem.sliceAsBytes(indices));

    // Update atlas texture if modified
    const atlas_modified = self.atlas.modified.load(.monotonic);
    if (atlas_modified != self.atlas_modified) {
        self.atlas_texture.upload(
            self.atlas.data,
            self.atlas.size,
            self.atlas.size,
            self.atlas.size, // bytes per row for grayscale
        );
        self.atlas_modified = atlas_modified;
    }

    // Render using indexed triangles
    encoder.setPipeline(&self.pipeline);
    encoder.setVertexBuffer(&self.vertex_buffer, 0, 0);
    encoder.setVertexBuffer(&self.screen_size_buffer, 0, 1);
    encoder.setFragmentTexture(&self.atlas_texture, 0);

    // Draw all glyphs in one call
    const index_count: u32 = @intCast(glyph_count * 6);
    encoder.drawIndexedPrimitives(.triangle, index_count, &self.index_buffer, 0);
}

/// Get glyph from cache or render and cache it
fn getOrRenderGlyph(self: *TextRenderer, glyph_id: u16) !Glyph {
    // Check cache first
    if (self.glyph_cache.get(glyph_id)) |cached| {
        return cached;
    }

    // Get metrics
    var glyph = try self.font.getGlyphMetrics(glyph_id);

    // Reserve space in atlas
    const region = self.atlas.reserve(
        self.allocator,
        glyph.width,
        glyph.height,
    ) catch |err| {
        if (err == Atlas.Error.AtlasFull) {
            // Try to grow atlas
            const new_size = self.atlas.size * 2;
            try self.atlas.grow(self.allocator, new_size);

            // Recreate texture with new size
            self.atlas_texture.deinit();
            self.atlas_texture = try self.device.createTextureWithFormat(new_size, new_size, .r8_unorm, false);

            // Try reserve again
            return self.getOrRenderGlyph(glyph_id);
        }
        return err;
    };

    // Render glyph to buffer
    const buffer_size = glyph.width * glyph.height;
    const buffer = try self.allocator.alloc(u8, buffer_size);
    defer self.allocator.free(buffer);

    try self.font.renderGlyph(glyph_id, buffer, glyph.width, glyph.height);

    // Upload to atlas
    self.atlas.set(region, buffer);

    // Find the actual glyph content bounds within the buffer
    // (CoreGraphics adds padding based on the glyph's bounding box origin)
    var min_x: u32 = glyph.width;
    var max_x: u32 = 0;
    var min_y: u32 = glyph.height;
    var max_y: u32 = 0;
    var found_pixel = false;

    var y: u32 = 0;
    while (y < glyph.height) : (y += 1) {
        var x: u32 = 0;
        while (x < glyph.width) : (x += 1) {
            if (buffer[y * glyph.width + x] > 0) {
                found_pixel = true;
                if (x < min_x) min_x = x;
                if (x > max_x) max_x = x;
                if (y < min_y) min_y = y;
                if (y > max_y) max_y = y;
            }
        }
    }

    if (found_pixel) {
        // Adjust atlas position and size to actual content
        glyph.atlas_x = region.x + min_x;
        glyph.atlas_y = region.y + min_y;
        glyph.width = max_x - min_x + 1;
        glyph.height = max_y - min_y + 1;
    } else {
        // Empty glyph (space character)
        glyph.atlas_x = region.x;
        glyph.atlas_y = region.y;
    }

    // Cache it
    try self.glyph_cache.put(self.allocator, glyph);

    return glyph;
}
