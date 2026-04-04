const std = @import("std");
const Session = @import("../playback/session.zig").Session;
const ui = @import("ui.zig");

pub const Viewer = struct {
    // Screen-space bounds (in points)
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    // Visibility & transform
    visible: bool,
    zoom: f32, // 1.0 = fit, 2.0 = 200%, etc.
    pan_x: f32, // Pan offset in normalized coords
    pan_y: f32,

    // Input state for delta calculation
    last_mouse_x: f32 = 0,
    last_mouse_y: f32 = 0,

    /// The session being displayed (not owned)
    session: ?*Session,

    /// Check if mouse is within viewer bounds
    pub fn isMouseOver(self: *const Viewer, imgui: *const ui.ImGui) bool {
        return imgui.mouse_x >= self.x and imgui.mouse_x < self.x + self.width and
            imgui.mouse_y >= self.y and imgui.mouse_y < self.y + self.height;
    }

    /// Handle pan/zoom input  - Called each frame.
    pub fn handleInput(self: *Viewer, imgui: *const ui.ImGui) void {
        const mouse_over = self.isMouseOver(imgui);

        // Calculate mouse delta
        const delta_x = imgui.mouse_x - self.last_mouse_x;
        const delta_y = imgui.mouse_y - self.last_mouse_y;
        self.last_mouse_x = imgui.mouse_x;
        self.last_mouse_y = imgui.mouse_y;

        if (!mouse_over) return;

        const session = self.session orelse return;
        const current_source = session.getCurrentSource();
        const video_width: f32 = @floatFromInt(current_source.resolution.width);
        const video_height: f32 = @floatFromInt(current_source.resolution.height);

        // Pan with middle mouse
        if (imgui.mouse_middle_down) {
            self.pan_x += delta_x;
            self.pan_y += delta_y;

            // Clamp pan to reasonable bounds
            const video_aspect = video_width / video_height;
            const viewer_aspect = self.width / self.height;

            var scale_x: f32 = 1.0;
            var scale_y: f32 = 1.0;
            if (video_aspect > viewer_aspect) {
                scale_y = viewer_aspect / video_aspect;
            } else {
                scale_x = video_aspect / viewer_aspect;
            }

            const max_pan_x = self.width * (scale_x * self.zoom * 0.5 + 0.45);
            const max_pan_y = self.height * (scale_y * self.zoom * 0.5 + 0.45);

            self.pan_x = std.math.clamp(self.pan_x, -max_pan_x, max_pan_x);
            self.pan_y = std.math.clamp(self.pan_y, -max_pan_y, max_pan_y);
        }

        // Zoom with scroll wheel
        if (imgui.scroll_y != 0) {
            self.zoom += imgui.scroll_y * -0.01;
            self.zoom = std.math.clamp(self.zoom, 0.01, 3000.0);
        }
    }

    pub fn deinit(self: *Viewer) void {
        _ = self;
    }
};
