const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const SourceMedia = @import("../io/media/media.zig").SourceMedia;
const Playback = @import("playback.zig").Playback;
const VideoMonitor = @import("video_monitor.zig").VideoMonitor;

const log = std.log.scoped(.session);

/// Session is a tagged union representing something viewable.
/// Either a single source or a timeline (sequence of sources).
pub const Session = union(enum) {
    source: SourceSession,
    timeline: TimelineSession,

    /// Get the current source to decode from.
    /// For SourceSession: returns the source directly.
    /// For TimelineSession: resolves current frame to the appropriate source.
    pub fn getCurrentSource(self: *Session) *SourceMedia {
        return switch (self.*) {
            .source => |s| s.source,
            .timeline => |*t| t.getCurrentSource(),
        };
    }

    pub fn deinit(self: *Session) void {
        switch (self.*) {
            .source => |*s| s.deinit(),
            .timeline => |*t| t.deinit(),
        }
    }
};

/// SourceSession: runtime state for viewing a single source.
/// Owns playback state, monitor thread, and decoder reference.
/// Must be heap-allocated (VideoMonitor stores &self.playback).
pub const SourceSession = struct {
    /// The source media being viewed (not owned)
    source: *SourceMedia,

    /// Playback state (owned)
    playback: Playback,

    /// Frame timing monitor (owned)
    monitor: VideoMonitor,

    /// Platform-specific decoder - lazy initialized (owned, optional)
    decoder: ?*anyopaque,

    /// Initialize a pre-allocated SourceSession.
    pub fn init(self: *SourceSession, source: *SourceMedia, io: Io, allocator: Allocator) !void {
        self.source = source;
        self.playback = Playback.init(0, source.duration_in_frames, source.duration_in_frames);
        self.decoder = null;

        // Monitor references &self.playback - stable because self is heap-allocated
        self.monitor = try VideoMonitor.init(
            source.frame_rate.get(),
            io,
            allocator,
            &self.playback,
        );

        log.debug("SourceSession created for: {s}", .{source.file_name});
    }

    pub fn deinit(self: *SourceSession) void {
        log.debug("SourceSession deinit for: {s}", .{self.source.file_name});
        self.monitor.deinit();
    }
};

/// TimelineSession: runtime state for viewing a timeline (sequence of clips).
/// Stub for now - will resolve frame index to appropriate source + offset.
pub const TimelineSession = struct {
    /// The timeline being viewed (not owned) - TODO: Timeline type
    // timeline: *Timeline,

    /// Playback state (owned)
    playback: Playback,

    /// Frame timing monitor (owned)
    monitor: VideoMonitor,

    /// Platform-specific decoder - lazy initialized (owned, optional)
    decoder: ?*anyopaque,

    /// TODO: Clip list for resolving frames
    /// clips: []Clip,
    /// Initialize a pre-allocated TimelineSession.
    pub fn init(self: *TimelineSession, duration_frames: i64, frame_rate: *const @import("../io/media/media.zig").Rational, io: Io, allocator: Allocator) !void {
        self.playback = Playback.init(0, duration_frames, duration_frames);
        self.decoder = null;

        self.monitor = try VideoMonitor.init(
            frame_rate.*,
            io,
            allocator,
            &self.playback,
        );

        log.debug("TimelineSession created", .{});
    }

    /// Get the source for the current frame.
    /// TODO: Walk clips to find which source contains current frame.
    pub fn getCurrentSource(self: *TimelineSession) *SourceMedia {
        _ = self;
        @panic("TimelineSession.getCurrentSource not implemented");
    }

    pub fn deinit(self: *TimelineSession) void {
        log.debug("TimelineSession deinit", .{});
        self.monitor.deinit();
    }
};
