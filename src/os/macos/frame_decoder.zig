const std = @import("std");

const metal = @import("metal");

const DecodedFrame = @import("../../io/decode/decoder.zig").DecodedFrame;
const videotoolbox = @import("../../io/decode/videotoolbox.zig");
const SourceMedia = @import("../../io/media/media.zig").SourceMedia;
const VideoMonitor = @import("../../playback/video_monitor.zig").VideoMonitor;
const Platform = @import("platform.zig").Platform;

/// Manages video frame decoding and GPU resource lifetime.
/// Decodes frames on demand using platform-specific decoder (VideoToolbox on macOS).
/// Keeps decoded frame buffers and Metal textures alive between vsync callbacks.
pub const FrameDecoder = struct {
    /// Reference to source media (owned by Core).
    source_media: *const SourceMedia,

    /// Platform-specific video decoder (VideoToolbox on macOS).
    decoder: videotoolbox.Decoder,

    /// UI frame counter.
    ui_frame: usize,

    /// Decoded frame resources - kept alive between vsync callbacks.
    packed_metal_texture: ?metal.MetalTexture,
    decoded_frame_buffer: ?DecodedFrame,
    texture_set_holder: ?videotoolbox.MetalTextureSet,

    pub fn init(platform: *Platform) !FrameDecoder {
        // Get source_media reference from Core (Core must load it first)
        const source_media = platform.core.source_media orelse {
            return error.NoMediaLoaded;
        };

        // Create platform-specific decoder
        var decoder = try videotoolbox.Decoder.init(
            source_media,
            @ptrCast(platform.window.device_ptr),
        );
        errdefer decoder.deinit();

        std.debug.print("✓ FrameDecoder initialized with {d}x{d} video\n\n", .{
            source_media.resolution.width,
            source_media.resolution.height,
        });

        return .{
            .source_media = source_media,
            .decoder = decoder,
            .decoded_frame_buffer = null,
            .ui_frame = 0,
            .packed_metal_texture = null,
            .texture_set_holder = null,
        };
    }

    pub fn deinit(self: *FrameDecoder) void {
        // Clean up decoded frame resources
        if (self.decoded_frame_buffer) |*df| df.deinit();
        if (self.texture_set_holder) |*ts| ts.deinit();

        self.decoder.deinit();
    }
};
