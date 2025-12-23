const std = @import("std");
const mov = @import("mov.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

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

    const verbose = if (argv.next()) |arg| std.mem.eql(u8, arg, "-v") else false;

    const tracks = try mov.parseMovFileVerbose(io, allocator, filename, verbose);
    defer {
        for (tracks) |*track| {
            track.deinit(allocator);
        }
        allocator.free(tracks);
    }

    for (tracks, 0..) |track, i| {
        std.debug.print("\n=== Track {d} ===\n", .{i});

        if (track.sizes) |sizes| {
            std.debug.print("  Sample count: {d}\n", .{sizes.len});
        }
        if (track.chunk_offsets) |offsets| {
            std.debug.print("  Chunk count: {d}\n", .{offsets.len});
        }
        if (track.stsc_entries) |entries| {
            std.debug.print("  STSC entries: {d}\n", .{entries.len});
        }

        // Build frame index if we have the required data
        if (track.sizes != null and
            track.chunk_offsets != null and
            track.stsc_entries != null)
        {
            std.debug.print("\n  Building Frame Index...\n", .{});
            const frames = try mov.buildFrameIndex(
                allocator,
                track.sizes.?,
                track.chunk_offsets.?,
                track.stsc_entries.?,
            );
            defer allocator.free(frames);

            // Print first 10 frames
            const max_to_show = @min(10, frames.len);
            for (frames[0..max_to_show], 0..) |frame, frame_idx| {
                std.debug.print("  Frame {d}: offset={d}, size={d}\n", .{ frame_idx, frame.offset, frame.size });
            }
            if (frames.len > 10) {
                std.debug.print("  ... ({d} more frames)\n\n", .{frames.len - 10});
            }

            // // Frame extraction
            // var x: u32 = 0;
            // while (x < 10) : (x += 1) {
            //     const read_frame = try mov.extractFrame(io, file, frames[x], allocator);
            //     defer allocator.free(read_frame);
            //
            //     std.debug.print("  Extracted frame {d}: {d} bytes\n", .{ x, read_frame.len });
            //     std.debug.print("  First 16 bytes: ", .{});
            //     for (read_frame[0..@min(16, read_frame.len)]) |byte| {
            //         std.debug.print("{x:0>2} ", .{byte});
            //     }
            //     std.debug.print("\n", .{});
            // }
        }
    }
}
