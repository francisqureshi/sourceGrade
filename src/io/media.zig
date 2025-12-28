const std = @import("std");
const mov = @import("mov.zig");
// const smpte = @import()

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Resolution = struct {
    width: usize,
    height: usize,
};

pub const Rational = extern struct {
    num: usize,
    den: usize,
};

pub const SourceMedia = struct {
    file_name: []const u8,
    file_path: []const u8,
    container_resolution: Resolution,
    resolution: Resolution,
    frame_rate: Rational,
    drop_frame: bool,
    frame_rate_float: f32,
    time_base: Rational,
    start_timecode: []const u8,
    end_timecode: []const u8,
    duration_in_frames: i64,
    start_frame_number: i64,
    end_frame_number: i64,
    reel_name: ?[]const u8,
    frames: []mov.FrameInfo,

    pub fn init(file_path: []const u8, file: std.Io.File, io: std.Io, allocator: std.mem.Allocator) !SourceMedia {
        const tracks = try mov.parseMovFile(io, allocator, file, false);
        defer {
            for (tracks) |*track| {
                track.deinit(allocator);
            }
            allocator.free(tracks);
        }

        // Single pass through tracks to extract all metadata
        var video_track: ?mov.TrackData = null;
        var timecode_track: ?mov.TrackData = null;

        for (tracks) |track| {
            if (track.video_info != null) video_track = track;
            if (track.timecode_info != null) timecode_track = track;
        }

        // Extract video metadata
        const vt = video_track orelse return error.NoVideoTrack;
        const vi = vt.video_info orelse return error.NoVideoInfo;
        const mdhd = vt.media_header orelse return error.NoMediaHeader;
        const stts = vt.stts_entries orelse return error.NoStts;

        const resolution = Resolution{ .width = vi.width, .height = vi.height };

        const frame_duration = if (stts.len > 0) stts[0].sample_duration else return error.NoFrameDuration;
        const frame_rate = Rational{ .num = mdhd.timescale, .den = frame_duration };
        const frame_rate_float = @as(f32, @floatFromInt(mdhd.timescale)) / @as(f32, @floatFromInt(frame_duration));

        // Extract timecode metadata if available
        const drop_frame = if (timecode_track) |tc|
            if (tc.timecode_info) |ti| ti.flags.drop_frame else false
        else
            false;

        const start_frame_number = if (timecode_track) |tc|
            tc.timecode_info.?.frame_number orelse 0
        else
            0;

        // Build frame index from video track
        const frames = if (vt.sizes != null and vt.chunk_offsets != null and vt.stsc_entries != null)
            try mov.buildFrameIndex(
                allocator,
                vt.sizes.?,
                vt.chunk_offsets.?,
                vt.stsc_entries.?,
            )
        else
            return error.InsufficientTrackData;

        const duration_in_frames = @as(i64, @intCast(frames.len));

        return .{
            .file_name = "none",
            .file_path = file_path,
            .resolution = resolution,
            .container_resolution = resolution, // Same as resolution for now
            .frame_rate = frame_rate,
            .frame_rate_float = frame_rate_float,
            .drop_frame = drop_frame,
            .time_base = frame_rate, // Same as frame_rate for now
            .start_timecode = undefined,
            .end_timecode = undefined,
            .duration_in_frames = duration_in_frames,
            .start_frame_number = start_frame_number,
            .end_frame_number = start_frame_number + duration_in_frames,
            .reel_name = null,
            .frames = frames,
        };
    }

    pub fn deinit(self: *SourceMedia, allocator: Allocator) void {
        allocator.free(self.frames);
    }
};

// const mediaPool struct {
//
// };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    const io = threaded.io();

    var argv = try std.process.argsWithAllocator(allocator);
    defer argv.deinit();

    _ = argv.next();
    const filepath = argv.next() orelse {
        std.debug.print("Usage: mov_parser <file.mov> [-v]\n", .{});
        return error.MissingArgument;
    };

    // Open file
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path = try std.fs.cwd().realpath(filepath, &path_buf);

    const file = try Io.File.openAbsolute(io, abs_path, .{});
    defer file.close(io);

    var test_source = try SourceMedia.init(filepath, file, io, allocator);
    defer test_source.deinit(allocator);

    std.debug.print("Resolution: {d}x{d}\n", .{ test_source.resolution.width, test_source.resolution.height });
    std.debug.print("Frame Rate: {d}/{d} = {d:.2} fps\n", .{ test_source.frame_rate.num, test_source.frame_rate.den, test_source.frame_rate_float });
    std.debug.print("Drop Frame: {}\n", .{test_source.drop_frame});
    std.debug.print("Start Source Frame: {d}\n", .{test_source.start_frame_number});
    std.debug.print("End Source Frame: {d}\n", .{test_source.end_frame_number});
    std.debug.print("Duration: {d} frames\n", .{test_source.duration_in_frames});
}
