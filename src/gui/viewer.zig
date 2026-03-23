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

    // Which VideoMonitor's output to display
    monitor_id: ?usize, // Index into Core.monitors array (future)
    // null = no monitor attached (shows placeholder)

    pub fn deinit(self: *Viewer) void {
        _ = self;
    }
};
