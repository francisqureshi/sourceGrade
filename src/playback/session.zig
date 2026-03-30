const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const SourceMedia = @import("../io/media/media.zig").SourceMedia;
const Playback = @import("playback.zig").Playback;
const VideoMonitor = @import("video_monitor.zig").VideoMonitor;

const log = std.log.scoped(.session);

/// Session bundles runtime state for viewing a source.
/// Owns playback state, monitor thread, and decoder reference.
/// Must be heap-allocated (VideoMonitor stores &self.playback).
pub const Session = struct {
    /// The source media being viewed (not owned)
    source: *SourceMedia,

    /// Playback state (owned)
    playback: Playback,

    /// Frame timing monitor (owned)
    monitor: VideoMonitor,

    /// Platform-specific decoder - lazy initialized (owned, optional)
    /// This will be set by Platform on first render.
    /// Type is ?*anyopaque because FrameDecoder is platform-specific.
    decoder: ?*anyopaque,

    /// Initialize a pre-allocated Session.
    /// Takes pointer to ensure stable address for internal references.
    /// VideoMonitor stores &self.playback, so Session must not be moved after init.
    pub fn init(self: *Session, source: *SourceMedia, io: Io, allocator: Allocator) !void {
        self.source = source;
        self.playback = Playback.init(0, source.duration_in_frames);
        self.decoder = null;

        // Monitor references &self.playback - stable because self is heap-allocated
        self.monitor = try VideoMonitor.init(
            &source.frame_rate.get(),
            io,
            allocator,
            &self.playback,
        );

        log.debug("Session created for: {s}", .{source.file_name});
    }

    pub fn deinit(self: *Session) void {
        log.debug("Session deinit for: {s}", .{self.source.file_name});
        self.monitor.deinit();
        // decoder cleanup is handled by Platform (it knows the concrete type)
    }
};
