const std = @import("std");
const media = @import("../io/media.zig");

pub const MonitorResult = union(enum) {
    ok,
    needs_decode: struct {
        frame_idx: usize,
    },
};

pub const MonitorStats = struct {
    time_since_last_frame_ns: u64 = 0,
    wall_clock_delta_ns: u64 = 0,
    frame_duration_ns: u64 = 0,
};

// FIXME: Make Video Monitor play as close to proper frame rates
// 25 / 3:2 pull down or whatever 25fps @60Hz looks like...
pub const VideoMonitor = struct {
    source_media: *media.SourceMedia,
    io: std.Io,
    decode_arena: std.heap.ArenaAllocator,

    ctrl_playback: f32,
    ctrl_playback_speed: f32, // 1.0 = normal speed, 0.5 = half speed, 2.0 = double speed

    last_timestamp: std.Io.Clock.Timestamp,
    playback_time_ns: u64,
    base_frame_duration_ns: u64,
    last_frame_time_ns: u64,
    current_frame_index: usize,
    last_decoded_frame_index: ?usize,

    monitor_stats: MonitorStats,

    /// Initialize with IO (for timestamps)
    pub fn init(
        source_media: *media.SourceMedia,
        io: std.Io,
        allocator: std.mem.Allocator,
    ) !VideoMonitor {
        const last_timestamp = std.Io.Clock.Timestamp.now(io, .awake);
        const base_frame_duration_ns: u64 = @intFromFloat(std.time.ns_per_s / source_media.frame_rate_float);

        return .{
            .source_media = source_media,
            .io = io,
            .decode_arena = std.heap.ArenaAllocator.init(allocator),

            .ctrl_playback = 0.0,
            .ctrl_playback_speed = 1.0,
            .last_timestamp = last_timestamp,

            .base_frame_duration_ns = base_frame_duration_ns,
            .playback_time_ns = 0,
            .last_frame_time_ns = 0,

            .current_frame_index = 0,
            .last_decoded_frame_index = null,
            .monitor_stats = .{},
        };
    }

    pub fn monitor(self: *VideoMonitor) MonitorResult {
        const now = std.Io.Clock.Timestamp.now(self.io, .awake);
        const elapsed_duration = self.last_timestamp.durationTo(now);
        const ui_frame_delta_ns: u64 = @intCast(@max(0, elapsed_duration.raw.nanoseconds));
        self.last_timestamp = now;
        // on macbook pro with 120 hz this is
        // - ~3ms
        // - ~8.5ms
        // - ~8.5ms
        // - ~10ms
        // - ~11-12ms
        //  About 40ms for 25fps playback but with triple buffered ui vsync of 8.3ms
        //  means 40ms is every 4.8 vsyncs..
        // std.debug.print("frame delta: {}ns\n", .{ui_frame_delta_ns});

        if (self.ctrl_playback != 0.0) {
            // Accumulate frame_delta_ns
            self.playback_time_ns += @as(
                u64,
                @intFromFloat(@as(f64, @floatFromInt(ui_frame_delta_ns)) * self.ctrl_playback_speed),
            );
        }

        const time_since_last_frame_ns = self.playback_time_ns - self.last_frame_time_ns;

        // Adjust frame duration by playback speed
        const frame_duration_ns = if (self.ctrl_playback_speed > 0.0)
            @as(u64, @intFromFloat(@as(f64, @floatFromInt(self.base_frame_duration_ns)) / self.ctrl_playback_speed))
        else
            self.base_frame_duration_ns;

        // Should we decode? Yes if:
        // - Frame index changed (first frame, seek, or playback advanced)
        // - OR we're playing and enough time has passed
        const advance = self.ctrl_playback != 0.0 and frame_duration_ns > 0 and time_since_last_frame_ns >= frame_duration_ns;

        // Advance to next frame only if playing and time elapsed
        if (advance) {
            if (self.ctrl_playback > 0.0) {
                // Advance Forward
                self.current_frame_index = (self.current_frame_index + 1) % @as(usize, @intCast(self.source_media.duration_in_frames));
            } else if (self.ctrl_playback < 0.0) {
                // Advance Backward (wrap at 0)
                self.current_frame_index = if (self.current_frame_index == 0)
                    @as(usize, @intCast(self.source_media.duration_in_frames - 1))
                else
                    self.current_frame_index - 1;
            }

            //INFO: new accurate timing
            self.last_frame_time_ns += frame_duration_ns;
        }

        const frame_changed = self.last_decoded_frame_index == null or self.last_decoded_frame_index.? != self.current_frame_index;

        // Write Stats
        self.monitor_stats.frame_duration_ns = frame_duration_ns;
        self.monitor_stats.wall_clock_delta_ns = ui_frame_delta_ns;
        self.monitor_stats.time_since_last_frame_ns = time_since_last_frame_ns;

        if (frame_changed) {

            // Mark this frame as decoded
            self.last_decoded_frame_index = self.current_frame_index;

            return .{
                .needs_decode = .{
                    .frame_idx = self.current_frame_index,
                },
            };
        }

        return .ok;
    }

    pub fn deinit(self: *VideoMonitor) void {
        self.decode_arena.deinit();
    }
};
