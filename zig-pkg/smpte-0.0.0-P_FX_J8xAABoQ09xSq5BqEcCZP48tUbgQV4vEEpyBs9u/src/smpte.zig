const std = @import("std");

// pub const Rational = struct {
//     num: usize,
//     den: usize,
// };

pub const SMPTEError = error{
    InvalidTimecodeFormat,
    FrameRateMismatch,
};

/// SMPTE timecode converter
pub const SMPTE = struct {
    fps: f64,
    drop_frame: bool,

    /// Initialize with frame rate and drop frame flag
    pub fn init(fps: f64, drop_frame: bool) SMPTE {
        return .{
            .fps = fps,
            .drop_frame = drop_frame,
        };
    }

    /// Initialize from Rational frame rate
    pub fn initFromRational(rational: anytype, drop_frame: bool) SMPTE {
        const fps = @as(f64, @floatFromInt(rational.num)) / @as(f64, @floatFromInt(rational.den));
        return .{
            .fps = fps,
            .drop_frame = drop_frame,
        };
    }

    /// Converts SMPTE timecode to frame count
    /// - Parameter tc: Timecode string in format "HH:MM:SS:FF" or "HH:MM:SS;FF" for drop frame
    /// - Returns: Frame count as i64
    pub fn getFrames(self: SMPTE, tc: []const u8) SMPTEError!i64 {
        // Parse timecode components
        var iter = std.mem.tokenizeAny(u8, tc, ":;");

        const hours_str = iter.next() orelse return SMPTEError.InvalidTimecodeFormat;
        const minutes_str = iter.next() orelse return SMPTEError.InvalidTimecodeFormat;
        const seconds_str = iter.next() orelse return SMPTEError.InvalidTimecodeFormat;
        const frames_str = iter.next() orelse return SMPTEError.InvalidTimecodeFormat;

        const hours = std.fmt.parseInt(i64, hours_str, 10) catch return SMPTEError.InvalidTimecodeFormat;
        const minutes = std.fmt.parseInt(i64, minutes_str, 10) catch return SMPTEError.InvalidTimecodeFormat;
        const seconds = std.fmt.parseInt(i64, seconds_str, 10) catch return SMPTEError.InvalidTimecodeFormat;
        const frames = std.fmt.parseInt(i64, frames_str, 10) catch return SMPTEError.InvalidTimecodeFormat;

        if (@as(f64, @floatFromInt(frames)) > self.fps) {
            return SMPTEError.FrameRateMismatch;
        }

        const total_minutes = 60 * hours + minutes;

        // Drop frame calculation using the Duncan/Heidelberger method
        if (self.drop_frame) {
            const drop_frames = @as(i64, @intFromFloat(@round(self.fps * 0.066666)));
            const time_base = @as(i64, @intFromFloat(@round(self.fps)));

            const hour_frames = time_base * 60 * 60;
            const minute_frames = time_base * 60;

            const frm = ((hour_frames * hours) + (minute_frames * minutes) + (time_base * seconds) + frames) -
                (drop_frames * (total_minutes - @divFloor(total_minutes, 10)));

            return frm;
        }
        // Non drop frame calculation
        else {
            const fps_int = @as(i64, @intFromFloat(@round(self.fps)));
            const frm = (total_minutes * 60 + seconds) * fps_int + frames;

            return frm;
        }
    }

    /// Converts frame count to SMPTE timecode
    /// - Parameter frames: Frame count
    /// - Parameter buffer: Buffer to write timecode string (must be at least 12 bytes)
    /// - Returns: Slice of buffer containing the timecode
    pub fn getTC(self: SMPTE, frames: i64, buffer: []u8) ![]const u8 {
        const abs_frames: u64 = @intCast(if (frames < 0) -frames else frames);

        // Drop frame calculation using the Duncan/Heidelberger method
        if (self.drop_frame) {
            const drop_frames: u64 = @intFromFloat(@round(self.fps * 0.066666));
            const frames_per_hour: u64 = @intFromFloat(@round(self.fps * 3600));
            const frames_per_24_hours = frames_per_hour * 24;
            const frames_per_10_minutes: u64 = @intFromFloat(@round(self.fps * 600));
            const frames_per_minute: u64 = @as(u64, @intFromFloat(@round(self.fps))) * 60 - drop_frames;

            var working_frames = @mod(abs_frames, frames_per_24_hours);

            const d = @divFloor(working_frames, frames_per_10_minutes);
            const m = @mod(working_frames, frames_per_10_minutes);

            if (m > drop_frames) {
                working_frames = working_frames + (drop_frames * 9 * d) +
                    drop_frames * @divFloor((m - drop_frames), frames_per_minute);
            } else {
                working_frames = working_frames + drop_frames * 9 * d;
            }

            const fr_round: u64 = @intFromFloat(@round(self.fps));
            const hr = @divFloor(working_frames, fr_round * 60 * 60);
            const mn = @mod(@divFloor(working_frames, fr_round * 60), 60);
            const sc = @mod(@divFloor(working_frames, fr_round), 60);
            const fr = @mod(working_frames, fr_round);

            return try std.fmt.bufPrint(buffer, "{:0>2}:{:0>2}:{:0>2};{:0>2}", .{ hr, mn, sc, fr });
        }
        // Non drop frame calculation
        else {
            const fps_int: u64 = @intFromFloat(@round(self.fps));

            const fr_hour = fps_int * 3600;
            const fr_min = fps_int * 60;

            const hr = @divFloor(abs_frames, fr_hour);
            const mn = @divFloor((abs_frames - hr * fr_hour), fr_min);
            const sc = @divFloor((abs_frames - hr * fr_hour - mn * fr_min), fps_int);
            const fr: u64 = @intFromFloat(@round(@as(f64, @floatFromInt(abs_frames - hr * fr_hour - mn * fr_min - sc * fps_int))));

            return try std.fmt.bufPrint(buffer, "{:0>2}:{:0>2}:{:0>2}:{:0>2}", .{ hr, mn, sc, fr });
        }
    }

    /// Add frames to a timecode
    pub fn addFrames(self: SMPTE, timecode: []const u8, frames: i64, buffer: []u8) ![]const u8 {
        const start_frames = try self.getFrames(timecode);
        const end_frames = start_frames + frames;
        return try self.getTC(end_frames, buffer);
    }

    /// Calculate the difference between two timecodes in frames
    pub fn frameDifference(self: SMPTE, start_tc: []const u8, end_tc: []const u8) !i64 {
        const start_frames = try self.getFrames(start_tc);
        const end_frames = try self.getFrames(end_tc);
        return end_frames - start_frames;
    }

    /// Check if a timecode is valid for the current frame rate
    pub fn isValidTimecode(self: SMPTE, timecode: []const u8) bool {
        _ = self.getFrames(timecode) catch return false;
        return true;
    }
};

// Tests
test "SMPTE non-drop frame 24fps" {
    const smpte = SMPTE.init(24.0, false);

    // Test frames to timecode
    var buffer: [12]u8 = undefined;
    const tc = try smpte.getTC(100, &buffer);
    try std.testing.expectEqualStrings("00:00:04:04", tc);

    // Test timecode to frames
    const frames = try smpte.getFrames("00:00:04:04");
    try std.testing.expectEqual(@as(i64, 100), frames);
}

test "SMPTE drop frame 29.97fps" {
    const smpte = SMPTE.init(29.97, true);

    // Test frames to timecode
    var buffer: [12]u8 = undefined;
    const tc = try smpte.getTC(1800, &buffer);
    try std.testing.expectEqualStrings("00:01:00;02", tc);

    // Test timecode to frames
    const frames = try smpte.getFrames("00:01:00;02");
    try std.testing.expectEqual(@as(i64, 1800), frames);
}

test "SMPTE add frames" {
    const smpte = SMPTE.init(24.0, false);

    var buffer: [12]u8 = undefined;
    const result = try smpte.addFrames("00:00:10:00", 240, &buffer);
    try std.testing.expectEqualStrings("00:00:20:00", result);
}

test "SMPTE frame difference" {
    const smpte = SMPTE.init(24.0, false);

    const diff = try smpte.frameDifference("00:00:10:00", "00:00:20:00");
    try std.testing.expectEqual(@as(i64, 240), diff);
}

test "SMPTE validate timecode" {
    const smpte = SMPTE.init(24.0, false);

    try std.testing.expect(smpte.isValidTimecode("00:00:10:00"));
    try std.testing.expect(!smpte.isValidTimecode("invalid"));
    try std.testing.expect(!smpte.isValidTimecode("00:00:10:99")); // Frame > fps
}
