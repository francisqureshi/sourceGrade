// Just test if we can see ANYTHING render at all
const std = @import("std");
const metal = @import("metal");
const c = @cImport({
    @cInclude("metal_window.h");
});

pub fn main() !void {
    const window = c.metal_window_create(800, 600, false);
    defer c.metal_window_release(window);
    
    c.metal_window_init_app();
    c.metal_window_show(window);
    
    std.debug.print("Window should be visible. Press Ctrl+C to exit.\n", .{});
    
    // Just keep app running to see if window appears
    c.metal_window_run_app();
}
