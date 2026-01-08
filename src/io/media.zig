const std = @import("std");
const mov = @import("mov.zig");
const smpte = @import("smpte");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const MediaContext = struct {
    file: Io.File,
    io: Io,
    allocator: Allocator,
};

pub const Resolution = struct {
    width: usize,
    height: usize,
};

pub const Rational = struct {
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
    codec: []const u8,
    stsd_data: []const u8,
    frames: []mov.FrameInfo,

    pub fn init(ctx: MediaContext) !SourceMedia {
        // file path and file name
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path_len = try ctx.file.realPath(ctx.io, &path_buf);
        const file_path_slice = path_buf[0..path_len];
        const file_path = try ctx.allocator.dupe(u8, file_path_slice);
        errdefer ctx.allocator.free(file_path);
        const file_name = try ctx.allocator.dupe(u8, std.fs.path.basename(file_path_slice));
        errdefer ctx.allocator.free(file_name);

        const tracks = try mov.parseMovFile(ctx.io, ctx.allocator, ctx.file, false);
        defer {
            for (tracks) |*track| {
                track.deinit(ctx.allocator);
            }
            ctx.allocator.free(tracks);
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

        const codec_array = vi.codec;
        const codec = try ctx.allocator.dupe(u8, &codec_array);
        errdefer ctx.allocator.free(codec);

        const stsd_data = if (vt.stsd_data) |data|
            try ctx.allocator.dupe(u8, data)
        else
            return error.NoStsdData;
        errdefer ctx.allocator.free(stsd_data);

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

        // Create SMPTE calculator
        const smpte_calc = smpte.SMPTE.initFromRational(frame_rate, drop_frame);
        var start_tc_buffer: [32]u8 = undefined;

        const start_timecode_slice = try smpte_calc.getTC(start_frame_number, &start_tc_buffer);
        const start_timecode = try ctx.allocator.dupe(u8, start_timecode_slice);

        // Build frame index from video track
        const frames = if (vt.sizes != null and vt.chunk_offsets != null and vt.stsc_entries != null)
            try mov.buildFrameIndex(
                ctx.allocator,
                vt.sizes.?,
                vt.chunk_offsets.?,
                vt.stsc_entries.?,
            )
        else
            return error.InsufficientTrackData;

        const duration_in_frames = @as(i64, @intCast(frames.len));
        const end_frame_number = start_frame_number + duration_in_frames - 1;

        var end_tc_buffer: [32]u8 = undefined;
        const end_timecode_slice = try smpte_calc.getTC(end_frame_number, &end_tc_buffer);
        const end_timecode = try ctx.allocator.dupe(u8, end_timecode_slice);

        return .{
            .file_name = file_name,
            .file_path = file_path,
            .resolution = resolution,
            .container_resolution = resolution, // Same as resolution for now
            .frame_rate = frame_rate,
            .frame_rate_float = frame_rate_float,
            .drop_frame = drop_frame,
            .time_base = frame_rate, // Same as frame_rate for now
            .start_timecode = start_timecode,
            .end_timecode = end_timecode,
            .duration_in_frames = duration_in_frames,
            .start_frame_number = start_frame_number,
            .end_frame_number = end_frame_number,
            .reel_name = null,
            .codec = codec,
            .stsd_data = stsd_data,
            .frames = frames,
        };
    }

    /// Read a frame into the provided buffer
    /// Returns the number of bytes written to the buffer
    /// Returns error.BufferTooSmall if buffer is insufficient
    pub fn readFrame(self: *SourceMedia, ctx: MediaContext, frame_index: usize, buffer: []u8) !usize {
        if (frame_index >= self.frames.len) return error.FrameIndexOutOfBounds;

        const frame_data = try mov.extractFrame(ctx.io, ctx.file, self.frames[frame_index], ctx.allocator);
        defer ctx.allocator.free(frame_data);

        if (buffer.len < frame_data.len) return error.BufferTooSmall;

        @memcpy(buffer[0..frame_data.len], frame_data);
        return frame_data.len;
    }

    /// Get the size of a frame without reading it
    /// Useful for allocating the correct buffer size
    pub fn getFrameSize(self: *SourceMedia, frame_index: usize) !usize {
        if (frame_index >= self.frames.len) return error.FrameIndexOutOfBounds;
        return self.frames[frame_index].size;
    }

    pub fn deinit(self: *SourceMedia, allocator: Allocator) void {
        allocator.free(self.file_path);
        allocator.free(self.file_name);
        allocator.free(self.codec);
        allocator.free(self.stsd_data);
        allocator.free(self.frames);
        allocator.free(self.start_timecode);
        allocator.free(self.end_timecode);
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
    const file_path = argv.next() orelse {
        std.debug.print("Usage: mov_parser <file.mov> [-v]\n", .{});
        return error.MissingArgument;
    };

    // Open file - if filepath is already absolute, use it; otherwise resolve it
    const file = if (std.fs.path.isAbsolute(file_path))
        try Io.Dir.openFileAbsolute(io, file_path, .{})
    else blk: {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = std.Io.Dir.cwd();
        const cwd_len = try cwd.realPath(io, &path_buf);
        const abs_path = try std.fmt.bufPrint(path_buf[cwd_len..], "/{s}", .{file_path});
        break :blk try Io.Dir.openFileAbsolute(io, path_buf[0 .. cwd_len + abs_path.len], .{});
    };
    defer file.close(io);

    const ctx = MediaContext{ .file = file, .io = io, .allocator = allocator };
    var test_source = try SourceMedia.init(ctx);
    defer test_source.deinit(allocator);

    std.debug.print("Resolution: {d}x{d}\n", .{ test_source.resolution.width, test_source.resolution.height });
    std.debug.print("Frame Rate: {d}/{d} = {d:.2} fps\n", .{ test_source.frame_rate.num, test_source.frame_rate.den, test_source.frame_rate_float });
    std.debug.print("Drop Frame: {}\n", .{test_source.drop_frame});
    std.debug.print("Start Source Frame: {d}\n", .{test_source.start_frame_number});
    std.debug.print("End Source Frame: {d}\n", .{test_source.end_frame_number});
    std.debug.print("Duration: {d} frames\n", .{test_source.duration_in_frames});
    std.debug.print("Start Source TC: {s}\n", .{test_source.start_timecode});
    std.debug.print("End Source TC: {s}\n", .{test_source.end_timecode});

    // Test reading a frame
    if (test_source.frames.len > 0) {
        const frame_size = try test_source.getFrameSize(0);
        std.debug.print("\nFirst frame size: {d} bytes\n", .{frame_size});

        const buffer = try allocator.alloc(u8, frame_size);
        defer allocator.free(buffer);

        const bytes_read = try test_source.readFrame(ctx, 0, buffer);
        std.debug.print("Read {d} bytes from frame 0\n", .{bytes_read});
    }
}
