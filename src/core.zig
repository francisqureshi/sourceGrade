const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const pg = @import("pg");
const pgdb = @import("io/db/pgdb.zig");
const db_test = @import("io/db/init_db.zig");
const sources = @import("io/media/sources.zig");

const Config = @import("config.zig").Config;
const SourceMedia = @import("io/media/media.zig").SourceMedia;
pub const Playback = @import("playback/playback.zig").Playback;
const VideoMonitor = @import("playback/video_monitor.zig").VideoMonitor;

const log = std.log.scoped(.core);

pub const Core = struct {
    allocator: Allocator,
    io: Io,

    cfg: Config,
    playback: Playback,

    // Core owns SourceMedia (will eventually be managed by MediaPool/Sources)
    source_media: ?*SourceMedia,

    video_monitors: std.ArrayList(VideoMonitor),

    pub fn init(allocator: Allocator, io: Io) !Core {
        // Load and parse all configuration
        const cfg = try Config.load(io, allocator);

        // Initialize playback state with test in/out points
        const playback: Playback = .{
            .playing = std.atomic.Value(f32).init(0.0),
            .speed = std.atomic.Value(f32).init(1.0),
            .loop = std.atomic.Value(bool).init(true),
            .in_point = cfg.testing.in_point,
            .out_point = cfg.testing.out_point,
        };

        return .{
            .allocator = allocator,
            .io = io,
            .cfg = cfg,
            .playback = playback,
            .source_media = null,
            .video_monitors = std.ArrayList(VideoMonitor).empty,
        };
    }

    /// Load source media from path and initialize VideoMonitor.
    /// Called after Platform is ready
    pub fn loadSourceMedia(self: *Core, video_path: []const u8) !void {
        const sm = try SourceMedia.init(video_path, self.io, self.allocator);

        self.source_media = try self.allocator.create(SourceMedia);
        self.source_media.?.* = sm;
        errdefer {
            self.source_media.?.deinit();
            self.allocator.destroy(self.source_media.?);
            self.source_media = null;
        }

        // Initialize VideoMonitor with loaded media
        // WARN: Probs need to decouple sourceMedia...
        const video_monitor = try VideoMonitor.init(
            &self.source_media.?.frame_rate.get(),
            self.io,
            self.allocator,
            &self.playback,
        );
        try self.video_monitors.append(self.allocator, video_monitor);

        log.debug("✓ Core loaded video: {d}x{d} @ {d:.2}fps, {d} frames", .{
            self.source_media.?.resolution.width,
            self.source_media.?.resolution.height,
            self.source_media.?.frame_rate_float,
            self.source_media.?.duration_in_frames,
        });
    }

    pub fn deinit(self: *Core) void {
        for (self.video_monitors.items) |*vm| vm.deinit();

        self.video_monitors.deinit(self.allocator);

        if (self.source_media) |sm| {
            sm.deinit();
            self.allocator.destroy(sm);
        }

        self.cfg.deinit(self.allocator);
    }
};
