const std = @import("std");
const smpte = @import("smpte");
const mov = @import("mov.zig");

const vtb = @import("decode/vtb_decode.zig");

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
    mctx: MediaContext,
    file_path: []const u8,
    file_name: []const u8,
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
    decoder: ?vtb.VideoToolboxDecoder,

    pub fn init(fp: []const u8, io: Io, allocator: Allocator) !SourceMedia {
        // Open video file

        const file = try Io.Dir.openFileAbsolute(io, fp, .{});
        errdefer file.close(io);

        // Create media context
        const mctx = MediaContext{ .file = file, .io = io, .allocator = allocator };

        const file_path = try mctx.allocator.dupe(u8, fp);
        errdefer mctx.allocator.free(file_path);

        const file_name = try mctx.allocator.dupe(u8, std.fs.path.basename(fp));
        errdefer mctx.allocator.free(file_name);

        const tracks = try mov.parseMovFile(mctx.io, mctx.allocator, mctx.file, false);
        defer {
            for (tracks) |*track| {
                track.deinit(mctx.allocator);
            }
            mctx.allocator.free(tracks);
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
        const codec = try mctx.allocator.dupe(u8, &codec_array);
        errdefer mctx.allocator.free(codec);

        const stsd_data = if (vt.stsd_data) |data|
            try mctx.allocator.dupe(u8, data)
        else
            return error.NoStsdData;
        errdefer mctx.allocator.free(stsd_data);

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
        std.debug.print("start_timecode_slice: {s}\n", .{start_timecode_slice});
        const start_timecode = try mctx.allocator.dupe(u8, start_timecode_slice);
        errdefer mctx.allocator.free(start_timecode);

        // Build frame index from video track
        const frames = if (vt.sizes != null and vt.chunk_offsets != null and vt.stsc_entries != null)
            try mov.buildFrameIndex(
                mctx.allocator,
                vt.sizes.?,
                vt.chunk_offsets.?,
                vt.stsc_entries.?,
            )
        else {
            // DEBUG: Print what's missing
            std.debug.print("❌ Missing track data for frame index:\n", .{});
            std.debug.print("   sizes: {}\n", .{vt.sizes != null});
            std.debug.print("   chunk_offsets: {}\n", .{vt.chunk_offsets != null});
            std.debug.print("   stsc_entries: {}\n", .{vt.stsc_entries != null});
            return error.InsufficientTrackData;
        };

        const duration_in_frames = @as(i64, @intCast(frames.len));
        const end_frame_number = start_frame_number + duration_in_frames - 1;

        var end_tc_buffer: [32]u8 = undefined;
        const end_timecode_slice = try smpte_calc.getTC(end_frame_number, &end_tc_buffer);
        const end_timecode = try mctx.allocator.dupe(u8, end_timecode_slice);
        errdefer mctx.allocator.free(end_timecode);

        return .{
            .mctx = mctx,
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
            .decoder = null,
        };
    }

    pub fn fromDb() !void {
        // TODO: Implement from DB load in init.
        return error.notYetImplementedWIP;
    }

    pub fn decodeSourceFrame(
        self: *SourceMedia,
        frame_idx: usize,
        metal_device: vtb.MTLDeviceRef, // Pass per-decode, not at init
    ) !vtb.DecodedFrame {
        // Lazy init with metal device
        if (self.decoder == null) {
            self.decoder = try vtb.VideoToolboxDecoder.init(self, metal_device);
        }
        return try self.decoder.?.decodeFrame(frame_idx);
    }

    /// Read a frame into the provided buffer
    /// Returns the number of bytes written to the buffer
    /// Returns error.BufferTooSmall if buffer is insufficient
    pub fn readFrame(self: *const SourceMedia, frame_index: usize, buffer: []u8) !usize {
        if (frame_index >= self.frames.len) return error.FrameIndexOutOfBounds;

        const frame_data = try mov.extractFrame(self.mctx.io, self.mctx.file, self.frames[frame_index], self.mctx.allocator);
        defer self.mctx.allocator.free(frame_data);

        if (buffer.len < frame_data.len) return error.BufferTooSmall;

        @memcpy(buffer[0..frame_data.len], frame_data);
        return frame_data.len;
    }

    /// Get the size of a frame without reading it
    /// Useful for allocating the correct buffer size
    pub fn getFrameSize(self: *const SourceMedia, frame_index: usize) !usize {
        if (frame_index >= self.frames.len) return error.FrameIndexOutOfBounds;
        return self.frames[frame_index].size;
    }

    pub fn deinit(self: *SourceMedia) void {
        // self.decoder.?.deinit();
        if (self.decoder) |*decoder| {
            decoder.deinit();
        }
        self.mctx.allocator.free(self.file_path);
        self.mctx.allocator.free(self.file_name);
        self.mctx.allocator.free(self.codec);
        self.mctx.allocator.free(self.stsd_data);
        self.mctx.allocator.free(self.frames);
        self.mctx.allocator.free(self.start_timecode);
        self.mctx.allocator.free(self.end_timecode);
        self.mctx.file.close(self.mctx.io);
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

    var test_source = try SourceMedia.init(file_path, io, allocator);
    defer test_source.deinit();

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

        const bytes_read = try test_source.readFrame(0, buffer);
        std.debug.print("Read {d} bytes from frame 0\n", .{bytes_read});
    }
}
