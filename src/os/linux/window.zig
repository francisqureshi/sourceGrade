const std = @import("std");
const sdl3 = @import("sdl3");

const log = std.log.scoped(.window);

/// Per-frame mouse position, button flags, and motion deltas.
pub const Mouse = struct {
    flags: sdl3.mouse.ButtonFlags,
    x: f32 = 0.0,
    y: f32 = 0.0,
    delta_x: f32 = 0.0,
    delta_y: f32 = 0.0,
};

/// Window dimensions in pixels.
const Size = struct {
    width: usize,
    height: usize,
};

/// SDL3 window wrapper. Owns the SDL window lifetime and exposes input state.
pub const Wnd = struct {
    window: sdl3.video.Window,
    closed: bool,
    mouse_state: Mouse,
    resized: bool,

    /// Initialises SDL3, loads the Vulkan library, and creates a resizable window
    /// sized to the primary display's usable bounds. Prefers Wayland if available.
    pub fn create(wnd_title: [:0]const u8, wnd_config: anytype) !Wnd {
        log.debug("Creating window", .{});

        const init_flags = sdl3.InitFlags{ .video = true };
        try sdl3.init(init_flags);
        if (!sdl3.c.SDL_SetHint("SDL_VIDEO_PREFER_WAYLAND", "1")) {
            // Handle error
        }

        sdl3.vulkan.loadLibrary(null) catch |err| {
            std.log.err("Failed to load Vulkan library: {s}", .{@errorName(err)});
            return error.VulkanNotSupported;
        };

        const WndSize = struct { w: u32, h: u32 };
        const size: WndSize = blk: {
            switch (wnd_config) {
                .maximised => {
                    const bounds = try sdl3.video.Display.getUsableBounds(try sdl3.video.Display.getPrimaryDisplay());
                    break :blk .{ .w = @as(u32, @intCast(bounds.w)), .h = @as(u32, @intCast(bounds.h)) };
                },
                .specific_size => |config| {
                    break :blk .{ .w = config.width, .h = config.height };
                },
            }
        };

        const window = try sdl3.video.Window.init(
            wnd_title,
            size.w,
            size.h,
            .{
                .resizable = true,
                .vulkan = true,
            },
        );

        log.debug("Created window", .{});

        return .{
            .window = window,
            .closed = false,
            .mouse_state = .{ .flags = .{
                .left = false,
                .right = false,
                .middle = false,
                .side1 = false,
                .side2 = false,
            } },
            .resized = false,
        };
    }

    /// Destroys the SDL window and shuts down SDL.
    pub fn cleanup(self: *Wnd) !void {
        log.debug("Destroying window", .{});
        self.window.deinit();
        sdl3.shutdown();
    }

    /// Returns the window's current size in pixels.
    pub fn getSize(self: *Wnd) !Size {
        const res = try sdl3.video.Window.getSizeInPixels(self.window);
        return Size{ .width = res[0], .height = res[1] };
    }

    /// Returns true if the given key is currently held down.
    pub fn isKeyPressed(self: *Wnd, key_code: sdl3.Scancode) bool {
        _ = self;
        const key_state = sdl3.keyboard.getState();
        return key_state[@intFromEnum(key_code)];
    }

    /// Drains the SDL event queue for one frame, updating `closed`, `resized`,
    /// and `mouse_state` (position, button flags, per-frame deltas).
    pub fn pollEvents(self: *Wnd) !void {
        self.resized = false;
        self.mouse_state.delta_x = 0.0;
        self.mouse_state.delta_y = 0.0;

        while (sdl3.events.poll()) |event| {
            switch (event) {
                .quit, .terminating => self.closed = true,
                .mouse_motion => {
                    self.mouse_state.delta_x += event.mouse_motion.x_rel;
                    self.mouse_state.delta_y += event.mouse_motion.y_rel;
                },
                .window_resized => {
                    self.resized = true;
                },
                else => {},
            }
        }
        const mouse_state = sdl3.mouse.getState();

        self.mouse_state.flags = mouse_state[0];
        self.mouse_state.x = mouse_state[1];
        self.mouse_state.y = mouse_state[2];
    }
};
