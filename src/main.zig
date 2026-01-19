const std = @import("std");
const builtin = @import("builtin");
const pg = @import("pg");
const media = @import("io/media.zig");
const db_test = @import("io/db/init_db.zig");
const renderer = @import("gpu/renderer.zig");
const vtbFW = @import("io/decode/videotoolbox_c.zig");

const vtb = @import("io/decode/vtb_decode.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
pub const log = std.log.scoped(.pgSQL);

fn testSourceIO() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize Io
    var threaded: Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    const io = threaded.io();

    // Open video file
    // const file_path = "/Users/fq/Desktop/AGMM/COS_AW25_4K_4444_LR001_LOG_S06.mov";
    // const file_path = "/Users/fq/Desktop/AGMM/ProRes444_with_Alpha.mov";
    const file_path = "/Users/fq/Desktop/AGMM/GreyRedHalf.mov";

    // const file_path = "/Users/mac10/Desktop/A_0005C014_251204_170032_p1CMW_S01.mov";

    // const file = Io.Dir.openFileAbsolute(io, video_path, .{}) catch |err| {
    //     std.debug.print("Could not open test video file: {}\n", .{err});
    //     return;
    // };
    // defer file.close(io);

    // Create media context
    // const mctx = media.MediaContext{ .file = file, .io = io, .allocator = allocator };

    // Parse media file
    // var source_media = try media.SourceMedia.init(mctx);
    var source_media = try media.SourceMedia.init(file_path, io, allocator);
    defer source_media.deinit();

    std.debug.print("\n✓ Parsed source media: {s}\n", .{source_media.file_name});
    std.debug.print("  Resolution: {d}x{d}\n", .{ source_media.resolution.width, source_media.resolution.height });
    std.debug.print("  Duration: {d} frames\n", .{source_media.duration_in_frames});
    std.debug.print("  Frame rate: {d}/{d} = {d:.2}fps\n", .{ source_media.frame_rate.num, source_media.frame_rate.den, source_media.frame_rate_float });
    std.debug.print("  StartTC: {s} --- End TC: {s}\n", .{ source_media.start_timecode, source_media.end_timecode });

    // Add parsed source to Db..
    // try db_test.addSourceToDB(allocator, source_media);

    std.debug.print("\n\n=== VideoToolBox Decoder ===\n\n", .{});
    // VideoToolBox Decode

    const frames: usize = 1;
    // const frames: usize = @intCast(source_media.duration_in_frames);

    for (0..frames) |f_idx| {
        const frame = try source_media.decodeSourceFrame(f_idx);
        defer frame.deinit();

        const width = vtbFW.CVPixelBufferGetWidth(frame.pixel_buffer);
        const height = vtbFW.CVPixelBufferGetHeight(frame.pixel_buffer);
        const format = vtbFW.CVPixelBufferGetPixelFormatType(frame.pixel_buffer);

        std.debug.print("✅ Decoded: {d}x{d}, format: 0x{X:0>8}\n", .{ width, height, format });
    }
}

fn app() !void {

    // Setup Main allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize GPU/rendering subsystem
    const config = renderer.RenderConfig{
        .use_display_p3 = true,
        .use_10bit = true,
    };

    var render_result = try renderer.initRenderContext(allocator, config);
    defer renderer.deinitRenderContext(allocator, &render_result);

    // Spawn render thread
    const thread = try std.Thread.spawn(.{}, renderer.renderThread, .{&render_result.context});
    thread.detach();

    // Run NSApplication runloop forever (this never returns)
    renderer.runEventLoop();

    // Code below never executes (runloop runs forever)
    unreachable;
}

pub fn main() !void {
    std.debug.print("=== sourceGrade ===\n\n", .{});

    // Test PgSQL
    // try db_test.testPgsql();

    // Test IO
    // try testSourceIO();

    // Run Gui / App
    try app();
}
