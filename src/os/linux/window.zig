const std = @import("std");
const sdl3 = @import("sdl3");

pub const Wnd = struct {
    window: sdl3.video.Window,
    closed: bool,
    // mouseState: MouseState,
    resized: bool,

    pub fn testSdl() !void {
        std.debug.print("sdl3: {any}\n", .{sdl3});
        // }
        //
        // pub fn create(wndTitle: [:0]const u8) !Wnd {
        // _ = wndTitle;
        // log.debug("Creating window", .{});

        // const initFlags = sdl3.InitFlags{ .video = true };
        // try sdl3.init(initFlags);

        const ver = sdl3.Version.get();
        std.debug.print("SDL version: {d}.{d}.{d}\n", .{
            ver.getMajor(), ver.getMinor(), ver.getMicro(),
        });
    }
};
