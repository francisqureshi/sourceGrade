const std = @import("std");
const media = @import("../io/media.zig");
const async_learning = @import("../async.zig");

const Io = std.Io;

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

pub const VideoMonitor = struct {
    source_media: *media.SourceMedia,
    io: Io,
    decode_arena: std.heap.ArenaAllocator,

    ctrl_playback: *std.atomic.Value(f32),
    playback_speed: *std.atomic.Value(f32),

    // Thread-safe shared state (read by vsync, written by monitor)
    current_frame_index: std.atomic.Value(usize),
    running: std.atomic.Value(bool), // Monitor thread stop signal

    // Monitor thread handle
    monitor_task: ?std.Io.Future(void) = null,

    last_timestamp: Io.Clock.Timestamp,
    playback_time_ns: u64,
    base_frame_duration_ns: u64,
    last_frame_time_ns: u64,
    last_decoded_frame_index: ?usize,

    monitor_stats: MonitorStats,

    //  debug fields:
    debug: bool,
    playback_started_at: ?Io.Clock.Timestamp, // When did playback start?
    total_frames_advanced: u64, // How many frames have we shown?
    last_drift_check_ns: u64, // When did we last print stats?

    /// Initialize with IO (for timestamps)
    pub fn init(
        source_media: *media.SourceMedia,
        io: Io,
        allocator: std.mem.Allocator,
        ctrl_playback: *std.atomic.Value(f32),
        playback_speed: *std.atomic.Value(f32),
    ) !VideoMonitor {
        const last_timestamp = Io.Clock.Timestamp.now(io, .awake);
        const base_frame_duration_ns: u64 = @intFromFloat(std.time.ns_per_s / source_media.frame_rate_float);

        return .{
            .source_media = source_media,
            .io = io,
            .decode_arena = std.heap.ArenaAllocator.init(allocator),

            .ctrl_playback = ctrl_playback,
            .playback_speed = playback_speed,
            .last_timestamp = last_timestamp,

            .base_frame_duration_ns = base_frame_duration_ns,
            .playback_time_ns = 0,
            .last_frame_time_ns = 0,

            //WARN: Maybe one day this is set by UI/ App / higher pwrs?
            .current_frame_index = std.atomic.Value(usize).init(0),
            .running = std.atomic.Value(bool).init(false),

            .last_decoded_frame_index = null,
            .monitor_stats = .{},

            // debug
            .debug = true,
            .playback_started_at = null,
            .total_frames_advanced = 0,
            .last_drift_check_ns = 0,
        };
    }

    fn monitorLoop(self: *VideoMonitor, io: Io) void {
        const start_time = std.Io.Clock.Timestamp.now(io, .awake);
        var next_tick_ns: u64 = 0;
        var last_frame_ns: u64 = 0; // Track when we last advanced a frame
        const duration: usize = @intCast(self.source_media.duration_in_frames);

        while (self.running.load(.acquire)) {
            // 1. Read playback state
            const direction = self.ctrl_playback.load(.acquire);
            const speed = self.playback_speed.load(.acquire);

            // Break if paused
            if (direction == 0.0) break;

            // Break if speed is 0 (can't calculate frame duration)
            const frame_duration_ns = if (speed > 0.0)
                @as(u64, @intFromFloat(@as(f64, @floatFromInt(self.base_frame_duration_ns)) / speed))
            else
                break; //WARN: how does this effect the button lol? maybe 0.0001 slider minimun is the solution..

            next_tick_ns += frame_duration_ns;

            // 2. Sleep until next frame (error compensation)
            const now = std.Io.Clock.Timestamp.now(io, .awake);
            const elapsed_ns: u64 = @intCast(@max(0, start_time.durationTo(now).raw.nanoseconds));
            const sleep_duration_ns: i64 = @as(i64, @intCast(next_tick_ns)) - @as(i64, @intCast(elapsed_ns));

            if (sleep_duration_ns > 0) {
                io.sleep(.fromNanoseconds(@intCast(sleep_duration_ns)), .awake) catch break;
            }

            // 3. Calculate how many frames to advance (handles high-speed playback)
            const now_after = std.Io.Clock.Timestamp.now(io, .awake);
            const total_elapsed: u64 = @intCast(@max(0, start_time.durationTo(now_after).raw.nanoseconds));
            const time_since_last_frame = total_elapsed - last_frame_ns;
            const frames_to_advance = time_since_last_frame / frame_duration_ns;

            if (frames_to_advance > 1) {
                std.debug.print("MULTI-FRAME ADVANCE: {d} frames\n", .{frames_to_advance});
            }

            // Update last frame time (consume the time for frames advanced)
            last_frame_ns += frames_to_advance * frame_duration_ns;

            // 4. Advance frame atomically (forward or backward)
            const old_idx = self.current_frame_index.load(.acquire);
            const new_idx = if (direction > 0.0)
                (old_idx + frames_to_advance) % duration // Forward
            else
                (old_idx + duration - (frames_to_advance % duration)) % duration; // Backward

            self.current_frame_index.store(new_idx, .release);
        }
    }

    pub fn startMonitor(self: *VideoMonitor, io: Io) !void {
        // Already running? Ignore (idempotent)
        if (self.monitor_task != null) return;

        // Set running flag
        self.running.store(true, .release);

        // Spawn concurrent task
        self.monitor_task = try io.concurrent(monitorLoop, .{ self, io });
    }

    pub fn stopMonitor(self: *VideoMonitor, io: Io) void {
        // Not running? Nothing to do :)
        if (self.monitor_task == null) return;

        // Signal thread to stop
        self.running.store(false, .release);

        // Cancel the task (interrupts sleep)
        self.monitor_task.?.cancel(io);
        self.monitor_task = null;
    }

    pub fn deinit(self: *VideoMonitor) void {
        self.stopMonitor(self.io);
        self.decode_arena.deinit();
    }

    // WARN: Previous PULL model that called every Vsync

    // if playing, monitor() checks to see if we need to advance a frame with playback speed in mind
    // pub fn monitor(self: *VideoMonitor) MonitorResult {
    //     const now = Io.Clock.Timestamp.now(self.io, .awake);
    //     const elapsed_duration = self.last_timestamp.durationTo(now);
    //     const ui_frame_delta_ns: u64 = @intCast(@max(0, elapsed_duration.raw.nanoseconds));
    //     self.last_timestamp = now;
    //     // on macbook pro with 120 hz this is
    //     // - ~3ms
    //     // - ~8.5ms
    //     // - ~8.5ms
    //     // - ~10ms
    //     // - ~11-12ms
    //     //  About 40ms for 25fps playback but with triple buffered ui vsync of 8.3ms
    //     //  means 40ms is every 4.8 vsyncs..
    //     // std.debug.print("frame delta: {}ns\n", .{ui_frame_delta_ns});
    //
    //     if (self.ctrl_playback.load(.acquire) != 0.0) {
    //         // debug start drift tracking on first playback
    //         if (self.playback_started_at == null) {
    //             self.playback_started_at = now;
    //             self.last_drift_check_ns = 0;
    //         }
    //
    //         // Accumulate real wall time (playback speed affects frame_duration_ns, not time accumulation)
    //         self.playback_time_ns += ui_frame_delta_ns;
    //     }
    //
    //     const time_since_last_frame_ns = self.playback_time_ns - self.last_frame_time_ns;
    //
    //     // Adjust frame duration by playback speed
    //     const frame_duration_ns = if (self.playback_speed.load(.acquire) > 0.0)
    //         @as(u64, @intFromFloat(@as(f64, @floatFromInt(self.base_frame_duration_ns)) / self.playback_speed.load(.acquire)))
    //     else
    //         self.base_frame_duration_ns;
    //
    //     // Calculate how many frames to advance (handles high-speed playback)
    //     // At high speeds (e.g., 4x), a single vsync might accumulate enough time for multiple frames
    //     if (self.ctrl_playback.load(.acquire) != 0.0 and frame_duration_ns > 0 and time_since_last_frame_ns >= frame_duration_ns) {
    //         // Integer division: how many complete frames fit in accumulated time?
    //         const frames_to_advance = time_since_last_frame_ns / frame_duration_ns;
    //         const duration = @as(usize, @intCast(self.source_media.duration_in_frames));
    //
    //         if (self.ctrl_playback.load(.acquire) > 0.0) {
    //             // Forward: jump multiple frames with wraparound
    //             const fwd = (self.current_frame_index.load(.acquire) + frames_to_advance) % duration;
    //             self.current_frame_index.store(fwd, .release);
    //         } else if (self.ctrl_playback.load(.acquire) < 0.0) {
    //             // Backward: add duration to ensure positive before modulo
    //             const bkwd = (self.current_frame_index.load(.acquire) + duration - (frames_to_advance % duration)) % duration;
    //
    //             self.current_frame_index.store(bkwd, .release);
    //         }
    //
    //         // Update timing state: consume the time for all advanced frames
    //         self.last_frame_time_ns += frames_to_advance * frame_duration_ns;
    //
    //         // Track total frames advanced (for drift checking)
    //         self.total_frames_advanced += frames_to_advance;
    //     }
    //
    //     if (self.debug) {
    //         if (self.playback_started_at) |start_time| {
    //             const wall_elapsed_ns: u64 = @intCast(@max(0, start_time.durationTo(now).raw.nanoseconds));
    //             const check_interval_ns: u64 = 2 * std.time.ns_per_s; // Check every 2 seconds
    //
    //             if (wall_elapsed_ns >= self.last_drift_check_ns + check_interval_ns) {
    //                 // Calculate expected vs actual frames
    //                 const wall_elapsed_s = @as(f64, @floatFromInt(wall_elapsed_ns)) / @as(f64, std.time.ns_per_s);
    //                 const expected_frames = wall_elapsed_s * self.source_media.frame_rate_float * self.playback_speed.load(.acquire);
    //                 const actual_frames = @as(f64, @floatFromInt(self.total_frames_advanced));
    //                 const drift_frames = actual_frames - expected_frames;
    //                 const drift_ms = (drift_frames / self.source_media.frame_rate_float) * 1000.0;
    //
    //                 std.debug.print("\n DRIFT CHECK @ {d:.1}s:\n", .{wall_elapsed_s});
    //                 std.debug.print("   Expected frames: {d:.1}\n", .{expected_frames});
    //                 std.debug.print("   Actual frames:   {}\n", .{self.total_frames_advanced});
    //                 std.debug.print("   Drift:           {d:.2} frames ({d:.1}ms)\n", .{ drift_frames, drift_ms });
    //                 std.debug.print("   Actual FPS:      {d:.2}\n\n", .{actual_frames / wall_elapsed_s});
    //
    //                 // Update last check time
    //                 self.last_drift_check_ns = wall_elapsed_ns;
    //             }
    //         }
    //     }
    //
    //     const frame_changed = self.last_decoded_frame_index == null or self.last_decoded_frame_index.? != self.current_frame_index.load(.acquire);
    //
    //     // Write Stats
    //     self.monitor_stats.frame_duration_ns = frame_duration_ns;
    //     self.monitor_stats.wall_clock_delta_ns = ui_frame_delta_ns;
    //     self.monitor_stats.time_since_last_frame_ns = time_since_last_frame_ns;
    //
    //     if (frame_changed) {
    //
    //         // Mark this frame as decoded
    //         self.last_decoded_frame_index = self.current_frame_index.load(.acquire);
    //
    //         return .{
    //             .needs_decode = .{
    //                 .frame_idx = self.current_frame_index.load(.acquire),
    //             },
    //         };
    //     }
    //
    //     return .ok;
    // }
};
