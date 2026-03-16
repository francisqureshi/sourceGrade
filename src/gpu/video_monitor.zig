const std = @import("std");
const media = @import("../io/media.zig");
const app = @import("../app.zig");

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

    playing: *std.atomic.Value(f32),
    playback_speed: *std.atomic.Value(f32),
    loop: *std.atomic.Value(bool),
    in_point: *isize,
    out_point: *isize,

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
        playback: *app.Playback,
    ) !VideoMonitor {
        const last_timestamp = Io.Clock.Timestamp.now(io, .awake);
        const base_frame_duration_ns: u64 = std.time.ns_per_s / (source_media.frame_rate.get().num / source_media.frame_rate.get().den);

        return .{
            .source_media = source_media,
            .io = io,
            .decode_arena = std.heap.ArenaAllocator.init(allocator),

            .playing = &playback.playing,
            .playback_speed = &playback.speed,
            .loop = &playback.loop,
            .in_point = &playback.in_point,
            .out_point = &playback.out_point,

            .last_timestamp = last_timestamp,

            .base_frame_duration_ns = base_frame_duration_ns,
            .playback_time_ns = 0,
            .last_frame_time_ns = 0,

            //WARN: Maybe one day this is set by UI/ App / higher pwrs?
            .current_frame_index = std.atomic.Value(usize).init(playback.current_frame),
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
            // Read playback state
            const direction = self.playing.load(.acquire);
            const speed = self.playback_speed.load(.acquire);
            const loop = self.loop.load(.acquire);

            // Break if paused
            if (direction == 0.0) break;

            // Break if speed is 0 (can't calculate frame duration)
            const frame_duration_ns = if (speed > 0.0)
                @as(u64, @intFromFloat(@as(f64, @floatFromInt(self.base_frame_duration_ns)) / speed))
            else
                break; //WARN: poss error with requiement for 0.0001 slider minimun is the solution..

            next_tick_ns += frame_duration_ns;

            // Sleep until next frame (error compensation)
            const now = std.Io.Clock.Timestamp.now(io, .awake);
            const elapsed_ns: u64 = @intCast(@max(0, start_time.durationTo(now).raw.nanoseconds));
            const sleep_duration_ns: i64 = @as(i64, @intCast(next_tick_ns)) - @as(i64, @intCast(elapsed_ns));

            if (sleep_duration_ns > 0) {
                io.sleep(.fromNanoseconds(@intCast(sleep_duration_ns)), .awake) catch break;
            }

            // Calculate how many frames to advance (handles high-speed playback)
            const now_after = std.Io.Clock.Timestamp.now(io, .awake);
            const total_elapsed: u64 = @intCast(@max(0, start_time.durationTo(now_after).raw.nanoseconds));
            const time_since_last_frame = total_elapsed - last_frame_ns;
            const frames_to_advance: usize = @intCast(time_since_last_frame / frame_duration_ns);

            if (frames_to_advance > 1) {
                std.debug.print("MULTI-FRAME ADVANCE: {d} frames\n", .{frames_to_advance});
            }

            // Update last frame time (consume the time for frames advanced)
            last_frame_ns += frames_to_advance * frame_duration_ns;

            // Advance frame atomically (forward or backward)
            const old_idx = self.current_frame_index.load(.acquire);
            const result = calcAdvance(
                @intCast(old_idx),
                direction,
                loop,
                self.in_point.*,
                self.out_point.*,
                @intCast(frames_to_advance),
                @intCast(duration),
            );

            self.current_frame_index.store(result.frame_idx, .release);

            // If we hit a boundary and not looping, stop playback
            if (result.hit_boundary and !loop) {
                self.playing.store(0.0, .release); // Set to paused
                self.running.store(false, .release); // Signal task is done
                break; //
            }
        }
    }

    const AdvanceResult = struct {
        frame_idx: usize,
        hit_boundary: bool,
    };

    fn calcAdvance(
        curr_idx: isize,
        direction: f32,
        loop: bool,
        in_point: isize,
        out_point: isize,
        frames_to_advance: isize,
        duration: isize,
    ) AdvanceResult {
        const range = duration - in_point - out_point;

        // Calculate raw new position
        const new_pos: isize = if (direction > 0.0)
            curr_idx + frames_to_advance
        else if (direction < 0.0)
            curr_idx - frames_to_advance
        else
            curr_idx;

        // Apply loop or clamp
        var frames: isize = undefined;
        var hit_boundary = false;

        if (loop) {
            // Loop: wrap within range
            const offset = new_pos - in_point;
            const wrapped = @mod(offset, range);
            frames = in_point + wrapped;
        } else {
            // No loop: clamp and detect boundary
            if (new_pos < in_point) {
                frames = in_point;
                hit_boundary = (new_pos != curr_idx);
            } else if (new_pos > out_point) {
                frames = out_point;
                hit_boundary = (new_pos != curr_idx);
            } else {
                frames = new_pos;
            }
        }

        return .{ .frame_idx = @intCast(frames), .hit_boundary = hit_boundary };
    }

    pub fn startMonitor(self: *VideoMonitor, io: Io) !void {
        // Clean up old task if it finished
        if (self.monitor_task) |*task| {
            // Check if task is still running
            if (self.running.load(.acquire)) {
                return; // Still running, don't start another
            }
            // Task finished, clean it up
            _ = task.await(io); // Wait for completion and cleanup
            self.monitor_task = null;
        }

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
};
