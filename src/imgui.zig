const std = @import("std");
const metal = @import("metal");

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

    /// Initialize the IMGUI context with triple-buffered GPU resources
    pub fn init(allocator: std.mem.Allocator, device: *metal.MetalDevice) !ImGuiContext {
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
            .display_width = 1920,
            .display_height = 1080,
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

    /// Add a filled triangle to the current frame's geometry
    pub fn addTriangle(self: *ImGuiContext, xa: f32, ya: f32, xb: f32, yb: f32, xc: f32, yc: f32, color: u32) !void {
        const base = @as(u16, @intCast(self.vertices.items.len));

        // Add 3 vertices (clockwise from top-left)
        try self.vertices.append(self.allocator, ImVertex.init(xa, ya, 0, 0, color));
        try self.vertices.append(self.allocator, ImVertex.init(xb, yb, 1, 0, color));
        try self.vertices.append(self.allocator, ImVertex.init(xc, yc, 1, 1, color));

        // Add 3 indices
        try self.indices.appendSlice(self.allocator, &[3]u16{
            base + 0, base + 1, base + 2, // First triangle
        });
    }

    /// Add a filled rectangle to the current frame's geometry
    /// Uses indexed triangles (4 vertices, 6 indices)
    pub fn addRect(self: *ImGuiContext, x: f32, y: f32, w: f32, h: f32, color: u32) !void {
        const base = @as(u16, @intCast(self.vertices.items.len));

        // Add 4 vertices (clockwise from top-left)
        try self.vertices.append(self.allocator, ImVertex.init(x, y, 0, 0, color));
        try self.vertices.append(self.allocator, ImVertex.init(x + w, y, 1, 0, color));
        try self.vertices.append(self.allocator, ImVertex.init(x + w, y + h, 1, 1, color));
        try self.vertices.append(self.allocator, ImVertex.init(x, y + h, 0, 1, color));

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
        try self.vertices.append(self.allocator, ImVertex.init(x, y, 0, 0, color));

        // add vertex for each sub division
        for (0..subdivisions) |slice| {
            const slice_angle = radien * @as(f32, @floatFromInt(slice));

            // x = a + r * cos(θ)
            const slice_x = x + r * std.math.cos(slice_angle);

            // y = b + r * sin(θ)
            const slice_y = y + r * std.math.sin(slice_angle);

            try self.vertices.append(self.allocator, ImVertex.init(slice_x, slice_y, 0, 0, color));
        }

        // Add indicess per subdivision..
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
        _ = label; // TODO: text rendering (requires font atlas)

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
};
