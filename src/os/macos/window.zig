const std = @import("std");

// C bridge for Swift window
const c = @cImport({
    @cInclude("metal_window.h");
});

/// macOS window wrapper using AppKit (NSWindow + CAMetalLayer).
/// Manages the native window handle, Metal layer, and device pointer.
pub const Window = struct {
    /// Opaque pointer to the NSWindow instance.
    handle: *anyopaque,
    /// Opaque pointer to the CAMetalLayer attached to the window's content view.
    layer: *anyopaque,
    /// Opaque pointer to the MTLDevice used by the layer.
    device_ptr: *anyopaque,
    width: usize,
    height: usize,

    /// Creates a new macOS window with a Metal-backed layer.
    /// Returns the window handle, layer, and device pointer.
    /// The window is created but not yet visible - call `show()` to display it.
    pub fn init(width: i32, height: i32, borderless: bool) !Window {
        const window = c.metal_window_create(width, height, borderless) orelse
            return error.WindowCreationFailed;

        std.debug.print("✓ Created Metal window\n", .{});

        const layer = c.metal_window_get_layer(window) orelse {
            c.metal_window_release(window);
            return error.LayerNotFound;
        };

        std.debug.print("✓ Got CAMetalLayer from window\n", .{});

        const device = c.metal_window_get_device(window) orelse {
            c.metal_window_release(window);
            return error.DeviceNotFound;
        };

        std.debug.print("✓ Got MTLDevice\n", .{});

        return .{
            .handle = window,
            .layer = layer,
            .device_ptr = device,
            .width = @intCast(width),
            .height = @intCast(height),
        };
    }

    /// Releases the native window resources.
    /// Must be called when the window is no longer needed.
    pub fn deinit(self: *Window) void {
        c.metal_window_release(self.handle);
    }

    /// Makes the window visible and brings it to front.
    /// Should be called after `initApp()`.
    pub fn show(self: *Window) void {
        c.metal_window_show(self.handle);
    }

    /// Gets the current mouse state: position, buttons, and scroll deltas.
    /// Coordinates are in window-local points (not pixels).
    /// `out_down` is true if the primary (left) mouse button is pressed.
    /// `out_middle_down` is true if the middle mouse button is pressed.
    /// Scroll deltas are one-shot values (reset to 0 after reading).
    /// Positive scrollY = scroll down, negative = scroll up.
    /// Positive scrollX = scroll right, negative = scroll left.
    pub fn getMouse(self: *Window, out_x: *f32, out_y: *f32, out_down: *bool, out_middle_down: *bool, out_scroll_x: *f32, out_scroll_y: *f32) void {
        c.metal_window_get_mouse_state(self.handle, out_x, out_y, out_down, out_middle_down, out_scroll_x, out_scroll_y);
    }

    /// Returns the backing scale factor (Retina multiplier).
    /// Typically 2.0 on Retina displays, 1.0 on standard displays.
    /// Use this to convert between points and pixels.
    pub fn getBackingScale(self: *Window) f64 {
        return c.metal_window_get_backing_scale(self.handle);
    }

    /// Sets the pixel format of the CAMetalLayer.
    /// Must match the pixel format used by render pipelines.
    /// Call this before creating pipelines.
    pub fn setLayerPixelFormat(self: *Window, pixel_format: u32) void {
        c.metal_layer_set_pixel_format(self.layer, pixel_format);
    }

    /// Acquires the next drawable from the CAMetalLayer.
    /// Returns null if no drawable is available (e.g., window minimized).
    /// The drawable must be released with `releaseDrawable()` after presenting.
    pub fn getNextDrawable(self: *Window) ?*anyopaque {
        return c.metal_layer_get_next_drawable(self.layer);
    }

    /// Initializes the NSApplication shared instance.
    /// Must be called before showing any windows.
    /// This sets up the macOS application environment.
    pub fn initApp() void {
        c.metal_window_init_app();
    }

    /// Runs the NSApplication main event loop.
    /// This function blocks forever, processing events until the app terminates.
    /// All rendering happens via CVDisplayLink callbacks while this runs.
    pub fn runEventLoop() void {
        c.metal_window_run_app();
    }
};

// ============================================================================
// CVDisplayLink wrapper
// ============================================================================

/// CVDisplayLink wrapper for vsync-synchronized callbacks.
/// Fires a callback at the display's refresh rate (e.g., 60Hz, 120Hz).
/// Used to drive the render loop in sync with the display.
pub const DisplayLink = struct {
    /// Opaque pointer to the CVDisplayLink instance.
    handle: *anyopaque,

    /// Creates a CVDisplayLink associated with the given window's display.
    /// The display link is created but not started - call `start()` to begin.
    pub fn init(window: *Window) !DisplayLink {
        const displaylink = c.metal_displaylink_create(window.handle) orelse
            return error.DisplayLinkCreationFailed;

        std.debug.print("✓ Created CVDisplayLink\n", .{});
        return .{ .handle = displaylink };
    }

    /// Stops and releases the CVDisplayLink.
    /// Must be called when the display link is no longer needed.
    pub fn deinit(self: *DisplayLink) void {
        c.metal_displaylink_release(self.handle);
    }

    /// Sets the callback function to be invoked on each vsync.
    /// The callback receives the userdata pointer.
    /// Note: By default, callback runs on a high-priority background thread.
    /// Use `setDispatchToMain(true)` to dispatch to the main thread instead.
    pub fn setCallback(
        self: *DisplayLink,
        callback: *const fn (?*anyopaque) callconv(.c) void,
        userdata: ?*anyopaque,
    ) void {
        c.metal_displaylink_set_callback(self.handle, callback, userdata);
    }

    /// When enabled, the callback is dispatched to the main thread.
    /// This is required for UI updates and most Metal rendering.
    /// When disabled, callback runs on CVDisplayLink's background thread.
    pub fn setDispatchToMain(self: *DisplayLink, enabled: bool) void {
        c.metal_displaylink_set_dispatch_to_main(self.handle, enabled);
    }

    /// Starts the display link, beginning vsync callbacks.
    /// Make sure to set a callback before starting.
    pub fn start(self: *DisplayLink) void {
        c.metal_displaylink_start(self.handle);
    }

    /// Stops the display link, pausing vsync callbacks.
    /// Can be restarted with `start()`.
    pub fn stop(self: *DisplayLink) void {
        c.metal_displaylink_stop(self.handle);
    }
};

// ============================================================================
// Drawable helpers (C bridge wrappers)
// ============================================================================

/// Extracts the MTLTexture from a CAMetalDrawable.
/// Returns the texture to render into, or null on failure.
/// The texture is owned by the drawable and will be presented when committed.
pub fn getDrawableTexture(drawable_ptr: *anyopaque) ?*anyopaque {
    return c.metal_drawable_get_texture(drawable_ptr);
}

/// Releases the CAMetalDrawable after presenting.
/// Must be called after `command_buffer.present()` and `commit()`.
pub fn releaseDrawable(drawable_ptr: *anyopaque) void {
    c.metal_drawable_release(drawable_ptr);
}

/// Releases a retained MTLTexture reference.
/// Call this after the texture is no longer needed.
pub fn releaseTexture(texture_ptr: *anyopaque) void {
    c.metal_texture_release(texture_ptr);
}
