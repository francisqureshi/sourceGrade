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

/// Entry for each font size, containing Font and GlyphCache
const FontEntry = struct {
    font: Font,
    glyph_cache: GlyphCache,

    fn init(font: Font) FontEntry {
        return .{
            .font = font,
            .glyph_cache = GlyphCache.init(),
        };
    }

    fn deinit(self: *FontEntry, allocator: Allocator) void {
        self.glyph_cache.deinit(allocator);
        var font = self.font;
        font.deinit();
    }
};

allocator: Allocator,
device: *metal.MetalDevice,
pipeline: metal.MetalRenderPipelineState,
atlas: Atlas,
atlas_texture: metal.MetalTexture,
font_name: [:0]const u8,
font_entries: std.AutoHashMap(u32, FontEntry), // font_size -> FontEntry
vertex_buffer: metal.MetalBuffer,
index_buffer: metal.MetalBuffer,
uniforms_buffer: metal.MetalBuffer,
max_vertices: usize,
atlas_modified: usize = 0,
// Vertex accumulation for batching multiple text calls
pending_vertices: std.ArrayList(TextVertex),

pub fn init(
    allocator: Allocator,
    device: *metal.MetalDevice,
    font_name: [:0]const u8,
    default_font_size: f32,
    atlas_size: u32,
    max_glyphs: usize,
    pixel_format: metal.PixelFormat,
) !TextRenderer {
    // Create default font
    var default_font = try Font.init(font_name, default_font_size);
    errdefer default_font.deinit();

    // Create font entries map
    var font_entries = std.AutoHashMap(u32, FontEntry).init(allocator);
    errdefer font_entries.deinit();

    // Add default font size
    const size_key: u32 = @intFromFloat(default_font_size);
    try font_entries.put(size_key, FontEntry.init(default_font));

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

    // Create index buffer - single quad pattern (like Ghostty)
    // Indices: 0,1,2, 0,2,3 (TR,BR,BL, TR,BL,TL)
    const quad_indices = [_]u16{ 0, 1, 2, 0, 2, 3 };
    var index_buffer = try device.createBuffer(@intCast(@sizeOf(u16) * quad_indices.len));
    errdefer index_buffer.deinit();
    index_buffer.upload(std.mem.sliceAsBytes(&quad_indices));

    // Create uniforms buffer and initialize it (matches TextUniforms in shader)
    var uniforms_buffer = try device.createBuffer(@sizeOf(TextUniforms));
    errdefer uniforms_buffer.deinit();

    // Initialize with default values (will be updated by setScreenSize and setDisplayP3)
    const initial_uniforms = TextUniforms{
        .screen_size = .{ 800.0, 600.0 },
        .use_display_p3 = true,
    };
    uniforms_buffer.upload(std.mem.asBytes(&initial_uniforms));

    // Load shaders
    const shader_source = @embedFile("TextShaders.metal");
    var library = try device.createLibraryFromSource(shader_source);
    defer library.deinit();

    var vertex_fn = try library.createFunction("textVertexShader");
    defer vertex_fn.deinit();

    var fragment_fn = try library.createFunction("textFragmentShader");
    defer fragment_fn.deinit();

    // Create pipeline with premultiplied alpha blending (like Ghostty)
    const pipeline_desc = metal.RenderPipelineDescriptor{
        .pixel_format = pixel_format, // Use provided pixel format (8-bit or 10-bit)
        .blend_enabled = true,
        .source_rgb_blend_factor = .one,
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
        .font_name = font_name,
        .font_entries = font_entries,
        .vertex_buffer = vertex_buffer,
        .index_buffer = index_buffer,
        .uniforms_buffer = uniforms_buffer,
        .max_vertices = max_vertices,
        .pending_vertices = std.ArrayList(TextVertex).empty,
    };
}

pub fn deinit(self: *TextRenderer) void {
    self.pending_vertices.deinit(self.allocator);

    // Deinit all font entries
    var iter = self.font_entries.iterator();
    while (iter.next()) |kv| {
        var entry = kv.value_ptr.*;
        entry.deinit(self.allocator);
    }
    self.font_entries.deinit();

    self.atlas.deinit(self.allocator);
    self.atlas_texture.deinit();
    self.vertex_buffer.deinit();
    self.index_buffer.deinit();
    self.uniforms_buffer.deinit();
    self.pipeline.deinit();
}

/// Uniforms struct (matches shader)
const TextUniforms = extern struct {
    screen_size: [2]f32,
    use_display_p3: bool,
};

/// Update screen size and Display P3 settings for coordinate transformation
pub fn setUniforms(self: *TextRenderer, width: f32, height: f32, use_display_p3: bool) void {
    const uniforms = TextUniforms{
        .screen_size = .{ width, height },
        .use_display_p3 = use_display_p3,
    };
    self.uniforms_buffer.upload(std.mem.asBytes(&uniforms));
}

/// Update screen size for coordinate transformation (keeps existing Display P3 setting)
pub fn setScreenSize(self: *TextRenderer, width: f32, height: f32) void {
    self.setUniforms(width, height, true); // Default to Display P3 enabled
}

/// Add text to the rendering batch (doesn't draw yet - call flush() to render)
pub fn renderText(
    self: *TextRenderer,
    encoder: *metal.MetalRenderEncoder,
    text: []const u8,
    x: f32,
    y: f32,
    font_size: f32,
    color: [4]u8,
) !void {
    _ = encoder; // Will be used in flush()
    if (text.len == 0) return;

    // Get or create font entry for this size
    const entry = try self.getOrCreateFontEntry(font_size);

    var cursor_x = x;

    for (text) |char| {
        const codepoint: u21 = char;

        // Get or create glyph
        const glyph_id = try entry.font.getGlyphID(codepoint);
        const glyph = try self.getOrRenderGlyph(entry, glyph_id);

        // Add vertex to pending batch
        try self.pending_vertices.append(self.allocator, .{
            .glyph_pos = .{ glyph.atlas_x, glyph.atlas_y },
            .glyph_size = .{ glyph.width, glyph.height },
            .bearings = .{ @intCast(glyph.bearing_x), @intCast(glyph.bearing_y) },
            .screen_pos = .{ cursor_x, y },
            .color = color,
        });

        cursor_x += glyph.advance_x;
    }
}

/// Flush all pending text to the GPU and render it
pub fn flush(self: *TextRenderer, encoder: *metal.MetalRenderEncoder) !void {
    if (self.pending_vertices.items.len == 0) return;

    // Upload all pending vertices to GPU
    self.vertex_buffer.upload(std.mem.sliceAsBytes(self.pending_vertices.items));

    // Upload atlas texture (only if modified)
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

    // Render using instanced indexed drawing
    encoder.setPipeline(&self.pipeline);
    encoder.setVertexBuffer(&self.vertex_buffer, 0, 0);
    encoder.setVertexBuffer(&self.uniforms_buffer, 0, 1);
    encoder.setFragmentTexture(&self.atlas_texture, 0);

    // Draw all glyphs: 6 indices per quad, N instances
    const glyph_count: u32 = @intCast(self.pending_vertices.items.len);
    encoder.drawIndexedPrimitivesInstanced(.triangle, 6, &self.index_buffer, 0, glyph_count);

    // Clear pending vertices for next frame
    self.pending_vertices.clearRetainingCapacity();
}

/// Get or create font entry for a given size
fn getOrCreateFontEntry(self: *TextRenderer, font_size: f32) !*FontEntry {
    const size_key: u32 = @intFromFloat(font_size);

    // Check if we already have this size
    if (self.font_entries.getPtr(size_key)) |entry| {
        return entry;
    }

    // Create new font for this size
    var font = try Font.init(self.font_name, font_size);
    errdefer font.deinit();

    // Add to map
    try self.font_entries.put(size_key, FontEntry.init(font));

    return self.font_entries.getPtr(size_key).?;
}

/// Get glyph from cache or render and cache it
fn getOrRenderGlyph(self: *TextRenderer, entry: *FontEntry, glyph_id: u16) !Glyph {
    // Check cache first
    if (entry.glyph_cache.get(glyph_id)) |cached| {
        return cached;
    }

    // Get metrics
    var glyph = try entry.font.getGlyphMetrics(glyph_id);

    // Render glyph to buffer first (to determine trimmed size)
    const buffer_size = glyph.width * glyph.height;
    const buffer = try self.allocator.alloc(u8, buffer_size);
    defer self.allocator.free(buffer);

    try entry.font.renderGlyph(glyph_id, buffer, glyph.width, glyph.height);

    // DEBUG: Check buffer content
    var has_content = false;
    var max_val: u8 = 0;
    for (buffer) |px| {
        if (px > 0) has_content = true;
        if (px > max_val) max_val = px;
    }
    std.debug.print("Buffer after render: has_content={}, max_val={}\n", .{ has_content, max_val });

    // // DEBUG: Find where the pixels actually are
    // var first_pixel_x: ?u32 = null;
    // var first_pixel_y: ?u32 = null;
    // var scan_y: u32 = 0;
    // while (scan_y < glyph.height and first_pixel_x == null) : (scan_y += 1) {
    //     var scan_x: u32 = 0;
    //     while (scan_x < glyph.width) : (scan_x += 1) {
    //         if (buffer[scan_y * glyph.width + scan_x] > 0) {
    //             first_pixel_x = scan_x;
    //             first_pixel_y = scan_y;
    //             break;
    //         }
    //     }
    // }
    // if (first_pixel_x) |fx| {
    //     std.debug.print("First pixel at ({},{})\n", .{ fx, first_pixel_y.? });
    //     std.debug.print("Buffer at first pixel (5x5):\n", .{});
    //     var dbg_y: u32 = 0;
    //     while (dbg_y < 5 and first_pixel_y.? + dbg_y < glyph.height) : (dbg_y += 1) {
    //         var dbg_x: u32 = 0;
    //         while (dbg_x < 5 and fx + dbg_x < glyph.width) : (dbg_x += 1) {
    //             const px = buffer[(first_pixel_y.? + dbg_y) * glyph.width + (fx + dbg_x)];
    //             std.debug.print("{x:0>2} ", .{px});
    //         }
    //         std.debug.print("\n", .{});
    //     }
    // } else {
    //     std.debug.print("No pixels found in buffer!\n", .{});
    // }

    // Reserve space in atlas (full size, no trimming like Ghostty)
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
            return self.getOrRenderGlyph(entry, glyph_id);
        }
        return err;
    };

    // Upload full buffer to atlas (no trimming, like Ghostty)
    self.atlas.set(region, buffer);

    // Update glyph atlas position
    glyph.atlas_x = region.x;
    glyph.atlas_y = region.y;

    std.debug.print("Glyph: atlas_pos=({},{}), size={}x{}, bearings=({},{})\n", .{
        glyph.atlas_x,
        glyph.atlas_y,
        glyph.width,
        glyph.height,
        glyph.bearing_x,
        glyph.bearing_y,
    });

    // Cache it
    try entry.glyph_cache.put(self.allocator, glyph);

    return glyph;
}
