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

    // Create index buffer - single quad pattern (like Ghostty)
    // Indices: 0,1,2, 0,2,3 (TR,BR,BL, TR,BL,TL)
    const quad_indices = [_]u16{ 0, 1, 2, 0, 2, 3 };
    var index_buffer = try device.createBuffer(@intCast(@sizeOf(u16) * quad_indices.len));
    errdefer index_buffer.deinit();
    index_buffer.upload(std.mem.sliceAsBytes(&quad_indices));

    // Create screen size buffer and initialize it
    var screen_size_buffer = try device.createBuffer(@sizeOf([2]f32));
    errdefer screen_size_buffer.deinit();

    // Initialize with default size (will be updated by setScreenSize)
    const initial_size = [2]f32{ 800.0, 600.0 };
    screen_size_buffer.upload(std.mem.asBytes(&initial_size));

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
        .pixel_format = .bgra8_unorm,
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

    // Prepare vertices - 1 vertex per glyph (instanced drawing)
    const max_glyphs = self.max_vertices / 4;
    if (text.len > max_glyphs) return error.TextTooLong;

    var vertices = try self.allocator.alloc(TextVertex, text.len);
    defer self.allocator.free(vertices);

    var cursor_x = x;

    for (text, 0..) |char, i| {
        const codepoint: u21 = char;

        // Get or create glyph
        const glyph_id = try self.font.getGlyphID(codepoint);
        const glyph = try self.getOrRenderGlyph(glyph_id);

        // Create 1 vertex per glyph (instanced drawing generates 4 corners)
        vertices[i] = .{
            .glyph_pos = .{ glyph.atlas_x, glyph.atlas_y },
            .glyph_size = .{ glyph.width, glyph.height },
            .bearings = .{ @intCast(glyph.bearing_x), @intCast(glyph.bearing_y) },
            .screen_pos = .{ cursor_x, y },
            .color = color,
        };

        cursor_x += glyph.advance_x;
    }

    // // DEBUG: Check what's in the atlas at first glyph position (AFTER trimming)
    // const first_glyph_x = vertices[0].glyph_pos[0];
    // const first_glyph_y = vertices[0].glyph_pos[1];
    // std.debug.print("Vertices[0] using atlas pos ({},{}) size ({},{})\n", .{
    //     first_glyph_x,
    //     first_glyph_y,
    //     vertices[0].glyph_size[0],
    //     vertices[0].glyph_size[1],
    // });
    // std.debug.print("Atlas at ({},{}) first 5x5:\n", .{ first_glyph_x, first_glyph_y });
    // var sample_y: u32 = 0;
    // while (sample_y < 5) : (sample_y += 1) {
    //     var sample_x: u32 = 0;
    //     while (sample_x < 5) : (sample_x += 1) {
    //         const px = self.atlas.data[(first_glyph_y + sample_y) * self.atlas.size + (first_glyph_x + sample_x)];
    //         std.debug.print("{x:0>2} ", .{px});
    //     }
    //     std.debug.print("\n", .{});
    // }

    // Upload vertices to GPU
    self.vertex_buffer.upload(std.mem.sliceAsBytes(vertices));

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
    encoder.setVertexBuffer(&self.screen_size_buffer, 0, 1);
    encoder.setFragmentTexture(&self.atlas_texture, 0);

    // Draw all glyphs: 6 indices per quad, text.len instances
    const glyph_count: u32 = @intCast(text.len);
    encoder.drawIndexedPrimitivesInstanced(.triangle, 6, &self.index_buffer, 0, glyph_count);
}

/// Get glyph from cache or render and cache it
fn getOrRenderGlyph(self: *TextRenderer, glyph_id: u16) !Glyph {
    // Check cache first
    if (self.glyph_cache.get(glyph_id)) |cached| {
        return cached;
    }

    // Get metrics
    var glyph = try self.font.getGlyphMetrics(glyph_id);

    // Render glyph to buffer first (to determine trimmed size)
    const buffer_size = glyph.width * glyph.height;
    const buffer = try self.allocator.alloc(u8, buffer_size);
    defer self.allocator.free(buffer);

    try self.font.renderGlyph(glyph_id, buffer, glyph.width, glyph.height);

    // DEBUG: Check buffer content
    var has_content = false;
    var max_val: u8 = 0;
    for (buffer) |px| {
        if (px > 0) has_content = true;
        if (px > max_val) max_val = px;
    }
    std.debug.print("Buffer after render: has_content={}, max_val={}\n", .{ has_content, max_val });

    // DEBUG: Find where the pixels actually are
    var first_pixel_x: ?u32 = null;
    var first_pixel_y: ?u32 = null;
    var scan_y: u32 = 0;
    while (scan_y < glyph.height and first_pixel_x == null) : (scan_y += 1) {
        var scan_x: u32 = 0;
        while (scan_x < glyph.width) : (scan_x += 1) {
            if (buffer[scan_y * glyph.width + scan_x] > 0) {
                first_pixel_x = scan_x;
                first_pixel_y = scan_y;
                break;
            }
        }
    }
    if (first_pixel_x) |fx| {
        std.debug.print("First pixel at ({},{})\n", .{ fx, first_pixel_y.? });
        std.debug.print("Buffer at first pixel (5x5):\n", .{});
        var dbg_y: u32 = 0;
        while (dbg_y < 5 and first_pixel_y.? + dbg_y < glyph.height) : (dbg_y += 1) {
            var dbg_x: u32 = 0;
            while (dbg_x < 5 and fx + dbg_x < glyph.width) : (dbg_x += 1) {
                const px = buffer[(first_pixel_y.? + dbg_y) * glyph.width + (fx + dbg_x)];
                std.debug.print("{x:0>2} ", .{px});
            }
            std.debug.print("\n", .{});
        }
    } else {
        std.debug.print("No pixels found in buffer!\n", .{});
    }

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
            return self.getOrRenderGlyph(glyph_id);
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
    try self.glyph_cache.put(self.allocator, glyph);

    return glyph;
}
