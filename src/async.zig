const std = @import("std");
const Io = std.Io;

// Clock A: ticks via timing  var with error compensation
pub fn clockA(io: Io, timing: i64) void {
    var tick: usize = 0;
    const timing_ns: u64 = @intCast(timing * std.time.ns_per_ms);
    const start_time = std.Io.Clock.real.now(io);
    var next_tick_ns: u64 = 0;
    var last_tick_actual_ns: u64 = 0;

    while (tick < 1500) { // Run for ~60 seconds at 40ms = 1500 ticks
        // Calculate when NEXT tick should happen (in nanoseconds from start)
        next_tick_ns += timing_ns;

        // Sleep until then
        const now = std.Io.Clock.real.now(io);
        const elapsed_ns: u64 = @intCast(@max(0, start_time.durationTo(now).nanoseconds));
        const sleep_duration_ns: i64 = @as(i64, @intCast(next_tick_ns)) - @as(i64, @intCast(elapsed_ns));

        if (sleep_duration_ns > 0) {
            // Check if sleep was cancelled (task.cancel was called)
            io.sleep(.fromNanoseconds(@intCast(sleep_duration_ns)), .awake) catch break;
        }

        tick += 1;

        const tick_actual_ns: u64 = @intCast(@max(0, start_time.durationTo(std.Io.Clock.real.now(io)).nanoseconds));

        // Print every 25 ticks (every ~1 second) to avoid spam
        if (tick % 25 == 0) {
            const delta_ns = tick_actual_ns - last_tick_actual_ns;
            const delta_ms = @as(f64, @floatFromInt(delta_ns)) / @as(f64, std.time.ns_per_ms);
            const target_ms = @as(f64, @floatFromInt(timing));
            const error_ms = delta_ms - target_ms;

            const ideal_time_ns = tick * timing_ns;
            const accumulated_error_ns: i64 = @as(i64, @intCast(tick_actual_ns)) - @as(i64, @intCast(ideal_time_ns));
            const accumulated_error_ms = @as(f64, @floatFromInt(accumulated_error_ns)) / @as(f64, std.time.ns_per_ms);

            std.debug.print("Tick {}: delta={d:.1}ms, target={d:.1}ms, error={d:.2}ms | accumulated_error={d:.2}ms\n", .{ tick, delta_ms, target_ms, error_ms, accumulated_error_ms });
        }

        last_tick_actual_ns = tick_actual_ns;
    }

    const final_now = std.Io.Clock.real.now(io);
    const total_elapsed_ns: u64 = @intCast(@max(0, start_time.durationTo(final_now).nanoseconds));
    const total_s = @as(f64, @floatFromInt(total_elapsed_ns)) / @as(f64, std.time.ns_per_s);
    std.debug.print("Clock A finished: {} ticks in {d:.2}s (expected: 60.0s)\n", .{ tick, total_s });
}

// Clock B: ticks every 1s
pub fn clockB(io: Io) void {
    var tick: usize = 0;
    while (true) {
        io.sleep(.fromSeconds(1), .awake) catch {};
        tick += 1;
        std.debug.print("T@{d} — Clock B: {d:.1}s\n", .{ std.Io.Clock.real.now(io), tick });
    }
}
