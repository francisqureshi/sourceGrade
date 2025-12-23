const std = @import("std");
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
    // allocator: std.mem.Allocator,
    file_name: []const u8,
    file_path: []const u8,
    container_resolution: Resolution,
    resolution: Resolution,
    frame_rate: Rational,
    frame_rate_float: f32,
    time_base: Rational,
    start_timecode: []const u8,
    end_timecode: []const u8,
    duration_in_frames: i64,
    start_frame_number: i64,
    end_frame_number: i64,
    drop_frame: bool,
    reel_name: ?[]const u8,
    interlaced: ?bool,
};

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
    const filename = argv.next() orelse {
        std.debug.print("Usage: mov_parser <file.mov> [-v]\n", .{});
        return error.MissingArgument;
    };
}
