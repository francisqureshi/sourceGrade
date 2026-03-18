const std = @import("std");
const metal = @import("metal");

const Platform = @import("platform.zig").Platform;
const ui = @import("../../gui/ui.zig");

const media = @import("../../io/media.zig");
const DecodedFrame = @import("../../io/decode/decoder.zig").DecodedFrame;

const videotoolbox = @import("../../io/decode/videotoolbox.zig");
const vm = @import("../../gpu/video_monitor.zig");

/// State that persists across render frames.
/// Heap-allocated on first frame and reused for the lifetime of the app.
pub const Render = struct {
    /// The loaded video source (file handle, decoder, metadata).
    source_media: *media.SourceMedia,

    /// Apple VideoToolBox deceoder
    decoder: videotoolbox.Decoder,

    /// Video playback controller (timing, frame index, decode triggers).
    video_monitor: vm.VideoMonitor,

    ui_frame: usize,

    // Video frame holders — keep CVPixelBuffer and Metal textures alive between frames
    packed_metal_texture: ?metal.MetalTexture,
    decoded_frame_buffer: ?DecodedFrame,
    texture_set_holder: ?videotoolbox.MetalTextureSet,

    pub fn init(platform: *Platform) !Render {
        const video_path = platform.app.cfg.testing.video_path;

        const sm = try media.SourceMedia.init(
            video_path,
            platform.app.io,
            platform.app.allocator,
        );

        var source_media = try platform.app.allocator.create(media.SourceMedia);
        source_media.* = sm;
        errdefer {
            source_media.deinit();
            platform.app.allocator.destroy(source_media);
        }

        var decoder = try videotoolbox.Decoder.init(
            source_media,
            @ptrCast(platform.window.device_ptr),
        );
        errdefer decoder.deinit();

        const video_monitor = try vm.VideoMonitor.init(
            &source_media.frame_rate.get(),
            platform.app.io,
            platform.app.allocator,
            &platform.app.playback,
        );

        std.debug.print("✓ Loaded video: {d}x{d} @ {d:.2}fps, {d} frames\n\n", .{
            source_media.resolution.width,
            source_media.resolution.height,
            source_media.frame_rate_float,
            source_media.duration_in_frames,
        });

        return .{
            .source_media = source_media,
            .decoder = decoder,
            .video_monitor = video_monitor,
            .decoded_frame_buffer = null,
            .ui_frame = 0,
            .packed_metal_texture = null,
            .texture_set_holder = null,
        };
    }

    pub fn deinit(self: *Render) void {

        // Clean up frame holders if present
        if (self.decoded_frame_buffer) |*df| df.deinit();
        if (self.texture_set_holder) |*ts| ts.deinit();

        // Clean up decoder and video monitor
        self.decoder.deinit();
        self.video_monitor.deinit();

        // Clean up source media
        self.source_media.deinit();
    }
};
