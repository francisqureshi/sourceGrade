const std = @import("std");
const builtin = @import("builtin");

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
pub const ImGui = struct {
    allocator: std.mem.Allocator,

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
    mouse_middle_down: bool,
    scroll_x: f32,
    scroll_y: f32,

    // Screen dimensions for coordinate mapping
    display_width: f32,
    display_height: f32,
    backing_scale_factor: f32, // HiDPI scale (1.0 = normal, 2.0 = Retina)

    // Font rendering (integrated)
    font_name: [:0]const u8,
    font_entries: std.AutoHashMap(u32, FontEntry), // font_size -> FontEntry
    atlas: Atlas,
    atlas_modified: usize,

    /// Initialize the IMGUI context with triple-buffered GPU resources
    pub fn init(allocator: std.mem.Allocator) !ImGui {

        // Initialize font system
        const font_name: [:0]const u8 = "IBM Plex Mono";
        // const font_name: [:0]const u8 = "Helvetica"; // check non-mono
        const default_font_size: f32 = 48.0;
        const atlas_size: u32 = 2048;

        // Create font entries map
        var font_entries = std.AutoHashMap(u32, FontEntry).init(allocator);
        errdefer font_entries.deinit();

        // Font initialisation is macOS only (CoreText) — stubbed on Linux
        if (comptime builtin.os.tag == .macos) {
            var default_font = try Font.init(font_name, default_font_size);
            errdefer default_font.deinit();
            const size_key: u32 = @intFromFloat(default_font_size);
            try font_entries.put(size_key, FontEntry.init(default_font));
        }

        // Create atlas
        var atlas = try Atlas.init(allocator, atlas_size, .grayscale);
        errdefer atlas.deinit(allocator);

        var ctx = ImGui{
            .allocator = allocator,
            .vertices = std.ArrayList(ImVertex).empty,
            .indices = std.ArrayList(u16).empty,
            .draw_cmds = std.ArrayList(ImDrawCmd).empty,
            .hot_id = 0,
            .active_id = 0,
            .mouse_x = 0,
            .mouse_y = 0,
            .mouse_down = false,
            .mouse_two_down = false,
            .mouse_middle_down = false,
            .scroll_x = 0,
            .scroll_y = 0,
            .display_width = 1600,
            .display_height = 900,
            .backing_scale_factor = 1.0,
            .font_name = font_name,
            .font_entries = font_entries,
            .atlas = atlas,
            .atlas_modified = 0,
        };

        // Pre-allocate capacity to avoid reallocations during frame construction
        try ctx.vertices.ensureTotalCapacity(allocator, MAX_VERTICES);
        try ctx.indices.ensureTotalCapacity(allocator, MAX_INDICES);
        try ctx.draw_cmds.ensureTotalCapacity(allocator, 256);

        return ctx;
    }

    /// Clean up GPU resources
    pub fn deinit(self: *ImGui) void {
        // Clean up font system
        var iter = self.font_entries.iterator();
        while (iter.next()) |kv| {
            var entry = kv.value_ptr.*;
            entry.deinit(self.allocator);
        }
        self.font_entries.deinit();
        self.atlas.deinit(self.allocator);

        self.vertices.deinit(self.allocator);
        self.indices.deinit(self.allocator);
        self.draw_cmds.deinit(self.allocator);
    }

    /// Call at the start of each frame to reset buffers
    /// Retains capacity to avoid reallocation
    pub fn newFrame(self: *ImGui) void {
        self.vertices.clearRetainingCapacity();
        self.indices.clearRetainingCapacity();
        self.draw_cmds.clearRetainingCapacity();
        self.hot_id = 0; // Reset hot tracking (active persists across frames)
    }

    /// Call after buildUI() to finalise the frame's draw command.
    /// Creates one draw cmd covering all accumulated geometry with a full-screen scissor.
    pub fn endFrame(self: *ImGui) !void {
        if (self.indices.items.len == 0) return;
        try self.draw_cmds.append(self.allocator, .{
            .elem_count = @intCast(self.indices.items.len),
            .clip_rect = .{ 0, 0, 10000, 10000 },
            .texture_id = null,
        });
    }

    /// Add a filled triangle to the current frame's geometry, xy is first point, other points followed are relative.
    pub fn addTriangle(self: *ImGui, x: f32, y: f32, xb: f32, yb: f32, xc: f32, yc: f32, color: u32) !void {
        const base = @as(u16, @intCast(self.vertices.items.len));

        // Add 3 vertices (UV 0,0 to skip texture sampling)
        try self.vertices.append(self.allocator, ImVertex.init(x, y, 0, 0, color));
        try self.vertices.append(self.allocator, ImVertex.init(x + xb, y + yb, 0, 0, color));
        try self.vertices.append(self.allocator, ImVertex.init(x + xc, y + yc, 0, 0, color));

        // Add 3 indices
        try self.indices.appendSlice(self.allocator, &[3]u16{
            base + 0, base + 1, base + 2,
        });
    }

    /// Add a filled rectangle to the current frame's geometry
    /// Uses indexed triangles (4 vertices, 6 indices)
    pub fn addRect(self: *ImGui, x: f32, y: f32, w: f32, h: f32, color: u32) !void {
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
    pub fn addCircle(self: *ImGui, x: f32, y: f32, r: f32, subdivisions: usize, color: u32) !void {
        const radien: f32 = ((2.0 * std.math.pi) / @as(f32, @floatFromInt(subdivisions)));
        const center = @as(u16, @intCast(self.vertices.items.len));

        // Center vertex
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
    pub fn addLine(self: *ImGui, x0: f32, y0: f32, x1: f32, y1: f32, color: u32, thickness: f32) !void {
        // Calculate perpendicular offset for line thickness
        const dx = x1 - x0;
        const dy = y1 - y0;
        const len = @sqrt(dx * dx + dy * dy);
        if (len < 0.001) return; // Degenerate line

        const nx = -dy / len * thickness * 0.5;
        const ny = dx / len * thickness * 0.5;

        const base = @as(u16, @intCast(self.vertices.items.len));

        // Create thick line as quad (UV 0,0 to skip texture sampling)
        try self.vertices.append(self.allocator, ImVertex.init(x0 + nx, y0 + ny, 0, 0, color));
        try self.vertices.append(self.allocator, ImVertex.init(x1 + nx, y1 + ny, 0, 0, color));
        try self.vertices.append(self.allocator, ImVertex.init(x1 - nx, y1 - ny, 0, 0, color));
        try self.vertices.append(self.allocator, ImVertex.init(x0 - nx, y0 - ny, 0, 0, color));

        try self.indices.appendSlice(self.allocator, &[6]u16{
            base + 0, base + 1, base + 2,
            base + 0, base + 2, base + 3,
        });
    }

    pub fn addRectOutline(self: *ImGui, x: f32, y: f32, w: f32, h: f32, color: u32, thickness: f32) !void {
        const t = thickness * 0.5;
        const base = @as(u16, @intCast(self.vertices.items.len));

        // Outer corners (clockwise from top-left)
        try self.vertices.append(self.allocator, ImVertex.init(x - t, y - t, 0, 0, color)); // 0: outer TL
        try self.vertices.append(self.allocator, ImVertex.init(x + w + t, y - t, 0, 0, color)); // 1: outer TR
        try self.vertices.append(self.allocator, ImVertex.init(x + w + t, y + h + t, 0, 0, color)); // 2: outer BR
        try self.vertices.append(self.allocator, ImVertex.init(x - t, y + h + t, 0, 0, color)); // 3: outer BL

        // Inner corners (clockwise from top-left)
        try self.vertices.append(self.allocator, ImVertex.init(x + t, y + t, 0, 0, color)); // 4: inner TL
        try self.vertices.append(self.allocator, ImVertex.init(x + w - t, y + t, 0, 0, color)); // 5: inner TR
        try self.vertices.append(self.allocator, ImVertex.init(x + w - t, y + h - t, 0, 0, color)); // 6: inner BR
        try self.vertices.append(self.allocator, ImVertex.init(x + t, y + h - t, 0, 0, color)); // 7: inner BL

        // 8 triangles forming the border (2 per side)
        try self.indices.appendSlice(self.allocator, &[_]u16{
            // Top edge
            base + 0, base + 1, base + 5,
            base + 0, base + 5, base + 4,
            // Right edge
            base + 1, base + 2, base + 6,
            base + 1, base + 6, base + 5,
            // Bottom edge
            base + 2, base + 3, base + 7,
            base + 2, base + 7, base + 6,
            // Left edge
            base + 3, base + 0, base + 4,
            base + 3, base + 4, base + 7,
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
    fn isInRect(self: *ImGui, x: f32, y: f32, w: f32, h: f32) bool {
        return self.mouse_x >= x and self.mouse_x < x + w and
            self.mouse_y >= y and self.mouse_y < y + h;
    }

    /// Immediate-mode button widget
    /// Returns true if button was clicked this frame
    pub fn textButton(self: *ImGui, id: u32, x: f32, y: f32, w: f32, h: f32, label: []const u8) !bool {
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
        } else if (is_hot and self.active_id == 0) {
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

        const font_size: f32 = 16;
        const text_width = self.measureText(label, font_size) catch 0;
        const text_x = x + (w / 2) - (text_width / 2);
        const text_y = y + (h / 2) - (font_size / 2);
        _ = TextWidget.addText(self, label, text_x, text_y, font_size, .{ 255, 255, 255, 255 }) catch {};

        return clicked;
    }

    pub const Icon = enum { play, reverse, pause, stop };

    /// Immediate-mode icon button (play/pause/stop/reverse)
    pub fn iconButton(self: *ImGui, id: u32, x: f32, y: f32, w: f32, h: f32, icon: Icon) !bool {
        const is_hot = self.isInRect(x, y, w, h);
        const is_active = self.active_id == id;

        if (is_hot) self.hot_id = id;

        var clicked = false;

        if (is_active) {
            if (!self.mouse_down) {
                if (is_hot) clicked = true;
                self.active_id = 0;
            }
        } else if (is_hot and self.active_id == 0) {
            if (self.mouse_down) self.active_id = id;
        }

        const bg_color = if (is_active)
            packColor(0.8, 0.3, 0.3, 1.0)
        else if (is_hot)
            packColor(0.5, 0.5, 0.5, 1.0)
        else
            packColor(0.3, 0.3, 0.3, 1.0);

        const icon_color = packColor(1, 1, 1, 1);

        try self.addRect(x, y, w, h, bg_color);

        const cx = x + w / 2;
        const cy = y + h / 2;
        const size = @min(w, h) * 0.4;

        switch (icon) {
            .play => {
                // Right-pointing triangle: base on left, tip on right, centered
                const half_h = size * 0.7;
                try self.addTriangle(cx - size * 0.4, cy - half_h, size, half_h, 0, half_h * 2, icon_color);
            },
            .reverse => {
                // Left-pointing triangle: base on right, tip on left, centered
                const half_h = size * 0.7;
                try self.addTriangle(cx + size * 0.4, cy - half_h, -size, half_h, 0, half_h * 2, icon_color);
            },
            .pause => {
                // Two vertical bars
                const bar_w = size * 0.35;
                const bar_h = size * 1.6;
                const gap = size * 0.25;
                try self.addRect(cx - gap - bar_w, cy - bar_h / 2, bar_w, bar_h, icon_color);
                try self.addRect(cx + gap, cy - bar_h / 2, bar_w, bar_h, icon_color);
            },
            .stop => {
                // Square
                try self.addRect(cx - size * 0.6, cy - size * 0.6, size * 1.2, size * 1.2, icon_color);
            },
        }

        return clicked;
    }

    /// Immediate-mode slider widget
    /// Returns true if value_ptr updates, and updates *f32 value_ptr
    pub fn slider(self: *ImGui, id: u32, x: f32, y: f32, w: f32, h: f32, value_ptr: *f32, min_val: f32, max_val: f32) !bool {
        // Hit-test uses the full height for easy clicking
        const is_hot = self.isInRect(x, y, w, h);
        const is_active = self.active_id == id;
        var val_changed: bool = false;

        if (is_hot) self.hot_id = id;

        // Handle dragging
        if (is_active) {
            if (self.mouse_down) {
                // Update value based on mouse position
                const t = std.math.clamp((self.mouse_x - x) / w, 0.0, 1.0);
                value_ptr.* = min_val + t * (max_val - min_val);
                val_changed = true;
            } else {
                self.active_id = 0;
            }
        } else if (is_hot and self.active_id == 0) {
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

        return val_changed;
    }

    /// Immediate-mode scrubber slider widget with in/out points
    /// Returns true if any value changed
    pub fn scrubBar(
        self: *ImGui,
        playhead_id: u32,
        in_id: u32,
        out_id: u32,
        track_id: u32,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        curr_frame: *usize,
        in_point: *usize,
        out_point: *usize,
        min_val: usize,
        max_val: usize,
    ) !bool {
        var val_changed: bool = false;
        const range_f: f32 = @floatFromInt(max_val - min_val);

        // Helper to convert frame to x position
        const frameToX = struct {
            fn f(frame: usize, min: usize, range: f32, bar_x: f32, bar_w: f32) f32 {
                const frame_f: f32 = @floatFromInt(frame - min);
                return bar_x + (frame_f / range) * bar_w;
            }
        }.f;

        // Helper to convert x position to frame
        const xToFrame = struct {
            fn f(mouse_x: f32, bar_x: f32, bar_w: f32, min: usize, range: f32) usize {
                const t = std.math.clamp((mouse_x - bar_x) / bar_w, 0.0, 1.0);
                return min + @as(usize, @intFromFloat(t * range));
            }
        }.f;

        // Thumb dimensions
        const playhead_width: f32 = 4;
        const io_width: f32 = 2;

        // Calculate positions
        const playhead_x = frameToX(curr_frame.*, min_val, range_f, x, w);
        const in_x = frameToX(in_point.*, min_val, range_f, x, w);
        const out_x = frameToX(out_point.*, min_val, range_f, x, w);

        // Hit test areas (slightly wider than visual for easier clicking)
        const hit_margin: f32 = 6;

        const playhead_hot = self.mouse_x >= playhead_x - hit_margin and self.mouse_x <= playhead_x + hit_margin and
            self.mouse_y >= y and self.mouse_y < y + h;
        const in_hot = self.mouse_x >= in_x - hit_margin and self.mouse_x <= in_x + hit_margin and
            self.mouse_y >= y and self.mouse_y < y + h;
        const out_hot = self.mouse_x >= out_x - hit_margin and self.mouse_x <= out_x + hit_margin and
            self.mouse_y >= y and self.mouse_y < y + h;
        const track_hot = self.mouse_x >= x - hit_margin and self.mouse_x <= x + w + hit_margin and
            self.mouse_y >= y and self.mouse_y < y + h;

        // Handle playhead dragging
        if (self.active_id == playhead_id) {
            if (self.mouse_down) {
                curr_frame.* = xToFrame(self.mouse_x, x, w, min_val, range_f);
                // Clamp playhead between in and out points
                // curr_frame.* = std.math.clamp(curr_frame.*, in_point.*, out_point.*);
                val_changed = true;
            } else {
                self.active_id = 0;
            }
        } else if (playhead_hot and self.mouse_down and self.active_id == 0) {
            self.active_id = playhead_id;
        }

        // Handle in point dragging
        if (self.active_id == in_id) {
            if (self.mouse_down) {
                in_point.* = xToFrame(self.mouse_x, x, w, min_val, range_f);
                // Clamp: in point can't go past out point
                if (in_point.* > out_point.*) in_point.* = out_point.*;
                val_changed = true;
            } else {
                self.active_id = 0;
            }
        } else if (in_hot and self.mouse_down and self.active_id == 0) {
            self.active_id = in_id;
        }

        // Handle out point dragging
        if (self.active_id == out_id) {
            if (self.mouse_down) {
                out_point.* = xToFrame(self.mouse_x, x, w, min_val, range_f);
                // Clamp: out point can't go before in point
                if (out_point.* < in_point.*) out_point.* = in_point.*;
                val_changed = true;
            } else {
                self.active_id = 0;
            }
        } else if (out_hot and self.mouse_down and self.active_id == 0) {
            self.active_id = out_id;
        }

        // Handle random track click/dragging
        if (self.active_id == track_id) {
            if (self.mouse_down) {
                curr_frame.* = xToFrame(self.mouse_x, x, w, min_val, range_f);
                val_changed = true;
            } else {
                self.active_id = 0;
            }
        } else if (track_hot and self.mouse_down and self.active_id == 0) {
            self.active_id = track_id;
        }

        // Update hot_id for cursor feedback
        if (playhead_hot) self.hot_id = playhead_id;
        if (in_hot) self.hot_id = in_id;
        if (out_hot) self.hot_id = out_id;
        if (playhead_hot) self.hot_id = track_id;

        // Draw track
        const track_height = h * 0.2;
        const track_y = y + (h - track_height) / 2;
        const track_color = packColor(0.4, 0.4, 0.4, 1.0);
        try self.addRect(x, track_y, w, track_height, track_color);

        // Draw in/out region (highlighted area between in and out)
        const region_color = packColor(0.7, 0.7, 0.7, 1.0);
        try self.addRect(in_x, track_y, out_x - in_x, track_height, region_color);

        // Draw in point (thin line)
        const in_color = if (self.active_id == in_id) packColor(0.5, 1.0, 0.5, 1.0) else packColor(0.3, 0.8, 0.3, 1.0);
        try self.addRect(in_x - io_width / 2, y, io_width, h, in_color);

        // Draw out point (thin line)
        const out_color = if (self.active_id == out_id) packColor(1.0, 0.5, 0.5, 1.0) else packColor(0.8, 0.3, 0.3, 1.0);
        try self.addRect(out_x - io_width / 2, y, io_width, h, out_color);

        // Draw playhead (thicker, on top)
        const playhead_color = if (self.active_id == playhead_id) packColor(1.0, 1.0, 1.0, 1.0) else packColor(0.9, 0.9, 0.9, 1.0);
        try self.addRect(playhead_x - playhead_width / 2, y + (h * 0.15), playhead_width, h * 0.7, playhead_color);

        return val_changed;
    }

    /// Get the number of indices to render
    pub fn getIndexCount(self: *ImGui) u32 {
        return @intCast(self.indices.items.len);
    }

    pub const TextAlign = enum { left, center, right };

    /// Simple text label with background and alignment
    pub fn textLabel(self: *ImGui, x: f32, y: f32, w: f32, h: f32, label: []const u8, bg_color: u32, text_color: [4]u8, alignment: TextAlign) !void {
        try self.addRect(x, y, w, h, bg_color);
        const font_size: f32 = 14;
        const padding: f32 = 4;

        const text_width = try self.measureText(label, font_size);
        const text_x = switch (alignment) {
            .left => x + padding,
            .center => x + (w / 2) - (text_width / 2),
            .right => x + w - text_width - padding,
        };
        const text_y = y + (h / 2) - (font_size / 2);

        _ = try TextWidget.addText(self, label, text_x, text_y, font_size, text_color);
    }

    /// Measure text width without rendering
    pub fn measureText(self: *ImGui, text: []const u8, font_size: f32) !f32 {
        if (comptime builtin.os.tag != .macos) {
            return 0;
        }

        const scaled_font_size = font_size * self.backing_scale_factor;
        const entry = try self.getOrCreateFontEntry(scaled_font_size);
        const scale = self.backing_scale_factor;

        var width: f32 = 0;
        for (text) |char| {
            const glyph_id = try entry.font.getGlyphID(char);
            const glyph = try self.getOrRenderGlyph(entry, glyph_id);
            width += glyph.advance_x / scale;
        }
        return width;
    }

    // ========================================================================
    // Text Rendering (Unified with shapes)
    // ========================================================================

    /// Get or create font entry for a given size
    fn getOrCreateFontEntry(self: *ImGui, font_size: f32) !*FontEntry {
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
    fn getOrRenderGlyph(self: *ImGui, entry: *FontEntry, glyph_id: u16) !Glyph {
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
    //         ui: *ImGui,
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
            ui: *ImGui,
            text: []const u8,
            x: f32,
            y: f32,
            font_size: f32,
            color: [4]u8,
        ) !TextWidget {
            // Text rendering is macOS only (CoreText) — stub on Linux
            if (comptime builtin.os.tag != .macos) {
                return .{ .parent = null, .width = 0, .height = font_size, .center_x = x };
            }
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

                // // INFO:Debug: draw glyph bounds
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

            // INFO: DEBUG: draw bounds of text
            // try ui.addRect(x, y, x_width, font_size, packColor(0.0, 1, 0.3, 0.4));

            return .{
                .parent = null, // parent is .... @fieldParentPtr() ??
                .width = x_width,
                .height = font_size,
                .center_x = cursor_x - (x_width / 2),
            };
        }
    };
};
