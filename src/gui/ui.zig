const std = @import("std");
const metal = @import("metal");

const Font = @import("text/font/Font.zig");
const Atlas = @import("text/font/Atlas.zig");
const Glyph = @import("text/font/Glyph.zig");
const GlyphCache = @import("text/font/GlyphCache.zig");

pub const layout = @import("layout.zig");

/// Vertex format for immediate-mode GUI rendering
/// Optimized for batched drawing with indexed triangles
pub const ImVertex = extern struct {
    position: [2]f32 align(4), // Screen space coordinates
    uv: [2]f32 align(4), // Texture coordinates (for font atlas, images)
    color: u32 align(4), // Packed RGBA8 color

    pub fn init(x: f32, y: f32, u: f32, v: f32, col: u32) ImVertex {
        return .{
            .position = .{ x, y },
            .uv = .{ u, v },
            .color = col,
        };
    }
};

/// Draw command for batched rendering
/// Each command represents a group of primitives with the same state
pub const ImDrawCmd = struct {
    elem_count: u32, // Number of indices
    clip_rect: [4]f32, // Clipping rectangle (x, y, width, height)
    texture_id: ?*anyopaque, // Optional texture binding
};

/// Ring buffer configuration
/// Triple-buffering prevents CPU/GPU sync stalls
const FRAMES_IN_FLIGHT = 3;
const MAX_VERTICES = 65536; // 64K vertices per frame
const MAX_INDICES = 131072; // 128K indices per frame (2x vertices for typical UI)

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

    fn deinit(self: *FontEntry, allocator: std.mem.Allocator) void {
        self.glyph_cache.deinit(allocator);
        var font = self.font;
        font.deinit();
    }
};

/// Main immediate-mode GUI context
/// Manages dynamic vertex/index buffers and UI state
pub const ImGuiContext = struct {
    allocator: std.mem.Allocator,

    // Ring buffers (triple-buffered for smooth CPU/GPU overlap)
    vertex_buffers: [FRAMES_IN_FLIGHT]metal.MetalBuffer,
    index_buffers: [FRAMES_IN_FLIGHT]metal.MetalBuffer,
    current_frame: usize,

    // CPU-side buffers (rebuilt each frame)
    vertices: std.ArrayList(ImVertex),
    indices: std.ArrayList(u16),
    draw_cmds: std.ArrayList(ImDrawCmd),

    // UI state tracking (immediate-mode pattern)
    hot_id: u32, // Widget under mouse cursor
    active_id: u32, // Widget being interacted with
    mouse_x: f32,
    mouse_y: f32,
    mouse_down: bool,
    mouse_two_down: bool,

    // Screen dimensions for coordinate mapping
    display_width: f32,
    display_height: f32,
    backing_scale_factor: f32, // HiDPI scale (1.0 = normal, 2.0 = Retina)

    // Font rendering (integrated)
    device: *metal.MetalDevice,
    font_name: [:0]const u8,
    font_entries: std.AutoHashMap(u32, FontEntry), // font_size -> FontEntry
    atlas: Atlas,
    atlas_texture: metal.MetalTexture,
    atlas_modified: usize,

    /// Initialize the IMGUI context with triple-buffered GPU resources
    pub fn init(allocator: std.mem.Allocator, device: *metal.MetalDevice, pixel_format: metal.PixelFormat) !ImGuiContext {
        _ = pixel_format;

        // Initialize font system
        const font_name: [:0]const u8 = "IBM Plex Mono";
        // const font_name: [:0]const u8 = "Helvetica"; // check non-mono
        const default_font_size: f32 = 48.0;
        const atlas_size: u32 = 2048;

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

        var ctx = ImGuiContext{
            .allocator = allocator,
            .vertex_buffers = undefined,
            .index_buffers = undefined,
            .current_frame = 0,
            .vertices = std.ArrayList(ImVertex).empty,
            .indices = std.ArrayList(u16).empty,
            .draw_cmds = std.ArrayList(ImDrawCmd).empty,
            .hot_id = 0,
            .active_id = 0,
            .mouse_x = 0,
            .mouse_y = 0,
            .mouse_down = false,
            .mouse_two_down = false,
            .display_width = 1600,
            .display_height = 900,
            .backing_scale_factor = 1.0,
            .device = device,
            .font_name = font_name,
            .font_entries = font_entries,
            .atlas = atlas,
            .atlas_texture = atlas_texture,
            .atlas_modified = 0,
        };

        // Pre-allocate capacity to avoid reallocations during frame construction
        try ctx.vertices.ensureTotalCapacity(allocator, MAX_VERTICES);
        try ctx.indices.ensureTotalCapacity(allocator, MAX_INDICES);
        try ctx.draw_cmds.ensureTotalCapacity(allocator, 256);

        // Create triple-buffered GPU buffers
        const vertex_buffer_size = MAX_VERTICES * @sizeOf(ImVertex);
        const index_buffer_size = MAX_INDICES * @sizeOf(u16);

        for (0..FRAMES_IN_FLIGHT) |i| {
            ctx.vertex_buffers[i] = try device.createBuffer(@intCast(vertex_buffer_size));
            ctx.index_buffers[i] = try device.createBuffer(@intCast(index_buffer_size));
        }

        return ctx;
    }

    /// Clean up GPU resources
    pub fn deinit(self: *ImGuiContext) void {
        // Clean up font system
        var iter = self.font_entries.iterator();
        while (iter.next()) |kv| {
            var entry = kv.value_ptr.*;
            entry.deinit(self.allocator);
        }
        self.font_entries.deinit();
        self.atlas.deinit(self.allocator);
        self.atlas_texture.deinit();

        for (0..FRAMES_IN_FLIGHT) |i| {
            self.vertex_buffers[i].deinit();
            self.index_buffers[i].deinit();
        }
        self.vertices.deinit(self.allocator);
        self.indices.deinit(self.allocator);
        self.draw_cmds.deinit(self.allocator);
    }

    /// Call at the start of each frame to reset buffers
    /// Retains capacity to avoid reallocation
    pub fn newFrame(self: *ImGuiContext) void {
        self.vertices.clearRetainingCapacity();
        self.indices.clearRetainingCapacity();
        self.draw_cmds.clearRetainingCapacity();
        self.hot_id = 0; // Reset hot tracking (active persists across frames)
    }

    /// Upload CPU-side geometry to GPU buffers
    /// Call after building UI, before rendering
    pub fn render(self: *ImGuiContext) void {
        if (self.vertices.items.len == 0) return;

        // Upload atlas texture if modified
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

        // Get current frame's buffers from ring
        var vb = &self.vertex_buffers[self.current_frame];
        var ib = &self.index_buffers[self.current_frame];

        // Upload CPU data to GPU
        const vertex_bytes = std.mem.sliceAsBytes(self.vertices.items);
        const index_bytes = std.mem.sliceAsBytes(self.indices.items);

        vb.upload(vertex_bytes);
        ib.upload(index_bytes);

        // Advance to next frame buffer
        self.current_frame = (self.current_frame + 1) % FRAMES_IN_FLIGHT;
    }

    /// Add a filled triangle to the current frame's geometry, xy is first point, other points followed are relative.
    pub fn addTriangle(self: *ImGuiContext, x: f32, y: f32, xb: f32, yb: f32, xc: f32, yc: f32, color: u32) !void {
        const base = @as(u16, @intCast(self.vertices.items.len));

        // Add 3 vertices (clockwise from top-left)
        try self.vertices.append(self.allocator, ImVertex.init(x, y, 0, 0, color));
        try self.vertices.append(self.allocator, ImVertex.init(x + xb, y + yb, 1, 0, color));
        try self.vertices.append(self.allocator, ImVertex.init(x + xc, y + yc, 1, 1, color));

        // Add 3 indices
        try self.indices.appendSlice(self.allocator, &[3]u16{
            base + 0, base + 1, base + 2, // First triangle
        });
    }

    /// Add a filled rectangle to the current frame's geometry
    /// Uses indexed triangles (4 vertices, 6 indices)
    pub fn addRect(self: *ImGuiContext, x: f32, y: f32, w: f32, h: f32, color: u32) !void {
        const base = @as(u16, @intCast(self.vertices.items.len));

        // Coordinates in points (shader will convert to clip space using display size)
        // Add 4 vertices with UVs at (0,0) to skip texture sampling
        try self.vertices.append(self.allocator, ImVertex.init(x, y, 0, 0, color));
        try self.vertices.append(self.allocator, ImVertex.init(x + w, y, 0, 0, color));
        try self.vertices.append(self.allocator, ImVertex.init(x + w, y + h, 0, 0, color));
        try self.vertices.append(self.allocator, ImVertex.init(x, y + h, 0, 0, color));

        // Add 6 indices (2 triangles)
        try self.indices.appendSlice(self.allocator, &[6]u16{
            base + 0, base + 1, base + 2, // First triangle
            base + 0, base + 2, base + 3, // Second triangle
        });
    }

    /// Add a filled circle to the current frame's geometry
    /// Uses indexed triangles to make a circle... ()
    pub fn addCircle(self: *ImGuiContext, x: f32, y: f32, r: f32, subdivisions: usize, color: u32) !void {
        const radien: f32 = ((2.0 * std.math.pi) / @as(f32, @floatFromInt(subdivisions)));
        const center = @as(u16, @intCast(self.vertices.items.len));

        // Centet vertex
        try self.vertices.append(self.allocator, ImVertex.init(x, y, 0, 0, packColor(0, 0, 0, 1)));

        // add vertex for each sub division
        for (0..subdivisions) |slice| {
            const slice_angle = radien * @as(f32, @floatFromInt(slice));

            // x = a + r * cos(θ)
            const slice_x = x + r * std.math.cos(slice_angle);

            // y = b + r * sin(θ)
            const slice_y = y + r * std.math.sin(slice_angle);

            try self.vertices.append(self.allocator, ImVertex.init(slice_x, slice_y, 0, 0, color));
        }

        // Add indicess per subdivision, last slice using 0th
        for (0..subdivisions) |slice| {
            const slice_index: u16 = @as(u16, @intCast(slice));
            if (slice < subdivisions - 1) {
                try self.indices.appendSlice(self.allocator, &[3]u16{
                    center + 0, center + 1 + slice_index, center + 1 + slice_index + 1,
                });
            } else {
                // do last triangle with wrap around somehow?
                try self.indices.appendSlice(self.allocator, &[3]u16{
                    center + 0, center + 1 + slice_index, center + 1,
                });
            }
        }
    }

    /// Add a line to the current frame's geometry
    /// Note: For proper line rendering, you may need a separate pipeline with line primitives
    pub fn addLine(self: *ImGuiContext, x0: f32, y0: f32, x1: f32, y1: f32, color: u32, thickness: f32) !void {
        // Calculate perpendicular offset for line thickness
        const dx = x1 - x0;
        const dy = y1 - y0;
        const len = @sqrt(dx * dx + dy * dy);
        if (len < 0.001) return; // Degenerate line

        const nx = -dy / len * thickness * 0.5;
        const ny = dx / len * thickness * 0.5;

        const base = @as(u16, @intCast(self.vertices.items.len));

        // Create thick line as quad
        try self.vertices.append(self.allocator, ImVertex.init(x0 + nx, y0 + ny, 0, 0, color));
        try self.vertices.append(self.allocator, ImVertex.init(x1 + nx, y1 + ny, 1, 0, color));
        try self.vertices.append(self.allocator, ImVertex.init(x1 - nx, y1 - ny, 1, 1, color));
        try self.vertices.append(self.allocator, ImVertex.init(x0 - nx, y0 - ny, 0, 1, color));

        try self.indices.appendSlice(self.allocator, &[6]u16{
            base + 0, base + 1, base + 2,
            base + 0, base + 2, base + 3,
        });
    }

    /// Pack RGBA floats (0-1) into a single u32 for vertex color
    pub fn packColor(r: f32, g: f32, b: f32, a: f32) u32 {
        const ri = @as(u32, @intFromFloat(@min(r * 255.0, 255.0)));
        const gi = @as(u32, @intFromFloat(@min(g * 255.0, 255.0)));
        const bi = @as(u32, @intFromFloat(@min(b * 255.0, 255.0)));
        const ai = @as(u32, @intFromFloat(@min(a * 255.0, 255.0)));
        return (ai << 24) | (bi << 16) | (gi << 8) | ri;
    }

    /// Pack byte color (0-255) into u32 RGBA
    pub fn packColorBytes(color: [4]u8) u32 {
        return @as(u32, color[0]) | (@as(u32, color[1]) << 8) | (@as(u32, color[2]) << 16) | (@as(u32, color[3]) << 24);
    }

    /// Unpack u32 color to RGBA floats (0-1)
    pub fn unpackColor(color: u32) [4]f32 {
        return .{
            @as(f32, @floatFromInt(color & 0xFF)) / 255.0,
            @as(f32, @floatFromInt((color >> 8) & 0xFF)) / 255.0,
            @as(f32, @floatFromInt((color >> 16) & 0xFF)) / 255.0,
            @as(f32, @floatFromInt((color >> 24) & 0xFF)) / 255.0,
        };
    }

    /// Check if mouse cursor is within rectangle bounds
    fn isInRect(self: *ImGuiContext, x: f32, y: f32, w: f32, h: f32) bool {
        return self.mouse_x >= x and self.mouse_x < x + w and
            self.mouse_y >= y and self.mouse_y < y + h;
    }

    /// Immediate-mode button widget
    /// Returns true if button was clicked this frame
    pub fn button(self: *ImGuiContext, id: u32, x: f32, y: f32, w: f32, h: f32, label: []const u8) !bool {
        const is_hot = self.isInRect(x, y, w, h);
        const is_active = self.active_id == id;

        if (is_hot) self.hot_id = id;

        var clicked = false;

        // Immediate-mode state machine
        if (is_active) {
            if (!self.mouse_down) {
                if (is_hot) clicked = true; // Released over button = click
                self.active_id = 0;
            }
        } else if (is_hot) {
            if (self.mouse_down) self.active_id = id; // Pressed over button
        }

        // Choose color based on state (darker = pressed, lighter = hover)
        const color = if (is_active)
            packColor(0.8, 0.3, 0.3, 1.0) // Active (pressed)
        else if (is_hot)
            packColor(0.5, 0.5, 0.5, 1.0) // Hot (hover)
        else
            packColor(0.3, 0.3, 0.3, 1.0); // Normal

        try self.addRect(x, y, w, h, color);

        const font_size = 16;
        _ = TextWidget.addText(self, label, ((w / 2) + x), (y + (h / 2) - (font_size / 2)), font_size, .{ 255, 255, 255, 255 }) catch {};

        return clicked;
    }

    /// Immediate-mode slider widget
    /// Returns new value, updates value_ptr
    pub fn slider(self: *ImGuiContext, id: u32, x: f32, y: f32, w: f32, h: f32, value_ptr: *f32, min_val: f32, max_val: f32) !void {
        // Hit-test uses the full height for easy clicking
        const is_hot = self.isInRect(x, y, w, h);
        const is_active = self.active_id == id;

        if (is_hot) self.hot_id = id;

        // Handle dragging
        if (is_active) {
            if (self.mouse_down) {
                // Update value based on mouse position
                const t = std.math.clamp((self.mouse_x - x) / w, 0.0, 1.0);
                value_ptr.* = min_val + t * (max_val - min_val);
            } else {
                self.active_id = 0;
            }
        } else if (is_hot) {
            if (self.mouse_down) self.active_id = id;
        }

        // Draw thin visual track (centered vertically in the hit area)
        const track_height = h * 0.3; // Thin track (30% of hit area)
        const track_y = y + (h - track_height) / 2; // Center vertically
        const track_color = if (is_active)
            packColor(0.6, 0.6, 0.6, 1.0)
        else if (is_hot)
            packColor(0.5, 0.5, 0.5, 1.0)
        else
            packColor(0.4, 0.4, 0.4, 1.0);

        try self.addRect(x, track_y, w, track_height, track_color);

        // Draw slider thumb (full height, centered on track)
        const t = (value_ptr.* - min_val) / (max_val - min_val);
        const thumb_width: f32 = 8;
        const thumb_x = x + t * w - thumb_width / 2;
        const thumb_color = packColor(1.0, 1.0, 1.0, 1.0);
        try self.addRect(thumb_x, y, thumb_width, h, thumb_color);
    }

    /// Get the vertex buffer for the previous frame (for rendering)
    /// Returns the buffer that was just uploaded by render()
    pub fn getVertexBuffer(self: *ImGuiContext) *metal.MetalBuffer {
        const prev_frame = (self.current_frame + FRAMES_IN_FLIGHT - 1) % FRAMES_IN_FLIGHT;
        return &self.vertex_buffers[prev_frame];
    }

    /// Get the index buffer for the previous frame (for rendering)
    pub fn getIndexBuffer(self: *ImGuiContext) *metal.MetalBuffer {
        const prev_frame = (self.current_frame + FRAMES_IN_FLIGHT - 1) % FRAMES_IN_FLIGHT;
        return &self.index_buffers[prev_frame];
    }

    /// Get the number of indices to render
    pub fn getIndexCount(self: *ImGuiContext) u32 {
        return @intCast(self.indices.items.len);
    }

    // ========================================================================
    // Text Rendering (Unified with shapes)
    // ========================================================================

    /// Get or create font entry for a given size
    fn getOrCreateFontEntry(self: *ImGuiContext, font_size: f32) !*FontEntry {
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
    fn getOrRenderGlyph(self: *ImGuiContext, entry: *FontEntry, glyph_id: u16) !Glyph {
        // Check cache first
        if (entry.glyph_cache.get(glyph_id)) |cached| {
            return cached;
        }

        // Get metrics
        var glyph = try entry.font.getGlyphMetrics(glyph_id);

        // Render glyph to buffer
        const buffer_size = glyph.width * glyph.height;
        const buffer = try self.allocator.alloc(u8, buffer_size);
        defer self.allocator.free(buffer);

        try entry.font.renderGlyph(glyph_id, buffer, glyph.width, glyph.height);

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
                return self.getOrRenderGlyph(entry, glyph_id);
            }
            return err;
        };

        // Upload buffer to atlas
        self.atlas.set(region, buffer);

        // Update glyph atlas position
        glyph.atlas_x = region.x;
        glyph.atlas_y = region.y;

        // Cache it
        try entry.glyph_cache.put(self.allocator, glyph);

        return glyph;
    }

    // pub const TextLabelWidget = struct {
    //     parent: ?f32,
    //     width: f32,
    //     height: f32,
    //     center_x: f32,
    //
    //     pub fn addTextLabel(
    //         ui: *ImGuiContext,
    //         // parent: null,
    //         text: []const u8,
    //         x: f32,
    //         y: f32,
    //         width: f32,
    //         height: f32,
    //         font_size: f32,
    //         // color: [4]u8,
    //         // bg_color: [4]u8,
    //     ) !void {
    //         // _ = bg_color;
    //         // _ = text;
    //         // _ = font_size;
    //
    //         // rectangle?
    //         addRect(ui, x, y, width, height, packColor(0.6, 0.6, 0.6, 1)) catch {};
    //
    //         // text_widget.width should be used to position addtext...
    //         const text_widget = try TextWidget.addText(ui, text, x, y, font_size, .{ 0, 0, 255, 255 });
    //         _ = text_widget;
    //         // std.debug.print("text_widget width: {d} px\n", .{text_widget.width});
    //     }
    // };

    pub const TextWidget = struct {
        parent: ?f32,
        width: f32,
        height: f32,
        center_x: f32,

        /// Add text to the rendering batch (generates quads, integrated with shapes)
        /// Text will be drawn in the order it's added relative to shapes
        pub fn addText(
            ui: *ImGuiContext,
            text: []const u8,
            x: f32,
            y: f32,
            font_size: f32,
            color: [4]u8,
        ) !TextWidget {
            // if (text.len == 0) return;

            // Scale font size by backing scale factor for HiDPI rendering
            const scaled_font_size = font_size * ui.backing_scale_factor;

            // Get or create font entry for this scaled size
            const entry = try ui.getOrCreateFontEntry(scaled_font_size);

            // Coordinates in points (NOT scaled - shader will handle conversion)
            var cursor_x = x;

            var x_width: f32 = 0;

            const baseline_y = y + (entry.font.ascent / ui.backing_scale_factor); // + to offset to y-top
            const packed_color = packColorBytes(color);

            var is_first_char = true;

            for (text) |char| {
                const codepoint: u21 = char;

                // Get or create glyph
                const glyph_id = try entry.font.getGlyphID(codepoint);
                const glyph = try ui.getOrRenderGlyph(entry, glyph_id);

                // Calculate screen quad in points
                // Glyph metrics are in pixels (rendered at scaled_font_size), convert to points
                const scale = ui.backing_scale_factor;
                const bearing_x_pts = @as(f32, @floatFromInt(glyph.bearing_x)) / scale;
                const bearing_y_pts = @as(f32, @floatFromInt(glyph.bearing_y)) / scale;
                const width_pts = @as(f32, @floatFromInt(glyph.width)) / scale;
                const height_pts = @as(f32, @floatFromInt(glyph.height)) / scale;

                // First char starts exactly at x, subsequent chars use bearing spacing
                const x1 = if (is_first_char) cursor_x else cursor_x + bearing_x_pts;
                const y1 = baseline_y - (bearing_y_pts + height_pts); // Top of glyph
                const x2 = x1 + width_pts;
                const y2 = y1 + height_pts; // Bottom of glyph

                // // Debug: draw glyph bounds
                // try ui.addRect(x1, y1, width_pts, height_pts, packColor(0.6, 0.6, 0.6, 0.6));

                // Calculate atlas UVs (no flip needed - CTFontDrawGlyphs renders correctly)
                const atlas_size_f: f32 = @floatFromInt(ui.atlas.size);
                const uv0_x = @as(f32, @floatFromInt(glyph.atlas_x)) / atlas_size_f;
                const uv0_y = @as(f32, @floatFromInt(glyph.atlas_y)) / atlas_size_f;
                const uv1_x = @as(f32, @floatFromInt(glyph.atlas_x + glyph.width)) / atlas_size_f;
                const uv1_y = @as(f32, @floatFromInt(glyph.atlas_y + glyph.height)) / atlas_size_f;

                // Add quad (4 vertices + 6 indices)
                const base_idx: u16 = @intCast(ui.vertices.items.len);

                // Add 4 vertices (TL, TR, BR, BL) with correct UVs
                try ui.vertices.append(ui.allocator, ImVertex.init(x1, y1, uv0_x, uv0_y, packed_color)); // TL
                try ui.vertices.append(ui.allocator, ImVertex.init(x2, y1, uv1_x, uv0_y, packed_color)); // TR
                try ui.vertices.append(ui.allocator, ImVertex.init(x2, y2, uv1_x, uv1_y, packed_color)); // BR
                try ui.vertices.append(ui.allocator, ImVertex.init(x1, y2, uv0_x, uv1_y, packed_color)); // BL

                // Add 6 indices (0,1,2, 0,2,3)
                try ui.indices.append(ui.allocator, base_idx + 0);
                try ui.indices.append(ui.allocator, base_idx + 1);
                try ui.indices.append(ui.allocator, base_idx + 2);
                try ui.indices.append(ui.allocator, base_idx + 0);
                try ui.indices.append(ui.allocator, base_idx + 2);
                try ui.indices.append(ui.allocator, base_idx + 3);

                // Advance cursor (glyph.advance_x is in pixels, convert to points)
                cursor_x += glyph.advance_x / scale;

                // Text Width
                x_width = cursor_x - x;

                is_first_char = false;
            }

            try ui.addRect(x, y, x_width, font_size, packColor(0.0, 1, 0.3, 0.4));

            return .{
                .parent = null, // parent is .... @fieldParentPtr() ??
                .width = x_width,
                .height = font_size,
                .center_x = cursor_x - (x_width / 2),
            };
        }
    };
};
