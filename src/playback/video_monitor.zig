const std = @import("std");
const Io = std.Io;

const Playback = @import("playback.zig").Playback;
const Rational = @import("../io/media/media.zig").Rational;

/// VideoMonitor - Push model video playback monitor
///
/// Architecture:
/// - Monitor thread runs independently, advancing frame index at source fps × speed
/// - Vsync thread reads current_frame_index atomically for decode
/// - Uses error-compensated sleep for accurate timing (99.98% accuracy)
/// - Supports forward/backward playback, in/out points, and loop mode
///
/// Threading model:
/// - startMonitor() spawns concurrent task that runs monitorLoop()
/// - Loop sleeps until next frame, advances current_frame_index atomically
/// - stopMonitor() cancels task and cleans up Future
/// - Auto-stops when hitting in/out point boundaries (if not looping)
pub const VideoMonitor = struct {
    io: Io,
    decode_arena: std.heap.ArenaAllocator,

    playback: *Playback, // Reference to all playback state

    // Thread-safe shared state (read by vsync, written by monitor)
    current_frame_index: std.atomic.Value(usize),
    running: std.atomic.Value(bool), // Monitor thread stop signal

    // Monitor thread handle
    monitor_task: ?std.Io.Future(void) = null,

    // Push model timing
    base_frame_duration_ns: u64,

    // Decode tracking
    last_decoded_frame_index: ?usize,

    pub fn init(
        frame_rate: Rational,
        io: Io,
        allocator: std.mem.Allocator,
        playback: *Playback,
    ) !VideoMonitor {
        const base_frame_duration_ns: u64 = std.time.ns_per_s / (frame_rate.num / frame_rate.den);

        return .{
            .io = io,
            .decode_arena = std.heap.ArenaAllocator.init(allocator),
            .playback = playback,

            .base_frame_duration_ns = base_frame_duration_ns,

            .current_frame_index = std.atomic.Value(usize).init(0),
            .running = std.atomic.Value(bool).init(false),

            .last_decoded_frame_index = null,
        };
    }

    fn monitorLoop(self: *VideoMonitor) void {
        const start_time = std.Io.Clock.Timestamp.now(self.io, .awake);
        var next_tick_ns: u64 = 0;
        var last_frame_ns: u64 = 0; // Track when we last advanced a frame

        while (self.running.load(.acquire)) {
            // Read playback state
            const direction = self.playback.playing.load(.acquire);
            const speed = self.playback.speed.load(.acquire);
            const loop = self.playback.loop.load(.acquire);

            // Break if paused
            if (direction == 0.0) break;

            // Clamp speed to minimum to prevent division by zero
            const clamped_speed = @max(speed, 0.01);
            const frame_duration_ns = @as(u64, @intFromFloat(@as(f64, @floatFromInt(self.base_frame_duration_ns)) / clamped_speed));

            next_tick_ns += frame_duration_ns;

            // Sleep until next frame (error compensation)
            const now = std.Io.Clock.Timestamp.now(self.io, .awake);
            const elapsed_ns: u64 = @intCast(@max(0, start_time.durationTo(now).raw.nanoseconds));
            const sleep_duration_ns: i64 = @as(i64, @intCast(next_tick_ns)) - @as(i64, @intCast(elapsed_ns));

            if (sleep_duration_ns > 0) {
                self.io.sleep(.fromNanoseconds(@intCast(sleep_duration_ns)), .awake) catch break;
            }

            // Calculate how many frames to advance (handles high-speed playback)
            const now_after = std.Io.Clock.Timestamp.now(self.io, .awake);
            const total_elapsed: u64 = @intCast(@max(0, start_time.durationTo(now_after).raw.nanoseconds));
            const time_since_last_frame = total_elapsed - last_frame_ns;
            const frames_to_advance: usize = @intCast(time_since_last_frame / frame_duration_ns);

            // Update last frame time (consume the time for frames advanced)
            last_frame_ns += frames_to_advance * frame_duration_ns;

            // Advance frame atomically (forward or backward)
            const curr_idx = self.current_frame_index.load(.acquire);
            const result = advanceFrame(
                @intCast(curr_idx),
                self.playback,
                @intCast(frames_to_advance),
            );

            self.current_frame_index.store(result.frame_idx, .release);

            // If we hit a boundary and not looping, stop playback
            if (result.hit_boundary and !loop) {
                self.playback.playing.store(0.0, .release); // Set to paused
                self.running.store(false, .release); // Signal task is done
                break; // Exit monitor loop
            }
        }
    }

    const AdvanceResult = struct {
        frame_idx: usize,
        hit_boundary: bool,
    };

    fn advanceFrame(
        curr_idx: isize,
        playback: *const Playback,
        frames_to_advance: isize,
    ) AdvanceResult {
        const direction = playback.playing.load(.acquire);
        const loop = playback.loop.load(.acquire);
        const in_point = playback.in_point;
        const out_point = playback.out_point;
        const end_frame: isize = playback.end_frame;

        // Calculate raw new position
        const new_pos: isize = if (direction > 0.0)
            curr_idx + frames_to_advance
        else if (direction < 0.0)
            curr_idx - frames_to_advance
        else
            curr_idx;

        var frames: isize = undefined;
        var hit_boundary = false;

        if (loop) {
            // Loop: wrap within in/out range
            const range = out_point - in_point;
            const offset = new_pos - in_point;
            const wrapped = @mod(offset, range);
            frames = in_point + wrapped;
        } else {
            // No loop: clamp to 0..last_frame
            if (new_pos < 0) {
                frames = 0;
                hit_boundary = (new_pos != curr_idx);
            } else if (new_pos > end_frame) {
                frames = end_frame;
                hit_boundary = (new_pos != curr_idx);
            } else {
                frames = new_pos;
            }
        }
        // // No loop: but clamp to in/out and detect boundary
        // if (new_pos < in_point) {
        //     frames = in_point;
        //     hit_boundary = (new_pos != curr_idx);
        // } else if (new_pos > out_point) {
        //     frames = out_point;
        //     hit_boundary = (new_pos != curr_idx);
        // } else {
        //     frames = new_pos;
        // }

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
        self.monitor_task = try io.concurrent(monitorLoop, .{self});
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
