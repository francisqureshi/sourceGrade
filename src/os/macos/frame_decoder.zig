const std = @import("std");

const metal = @import("metal");

const DecodedFrame = @import("../../io/decode/decoder.zig").DecodedFrame;
const videotoolbox = @import("../../io/decode/videotoolbox.zig");
const Session = @import("../../playback/session.zig").Session;
const SourceMedia = @import("../../io/media/media.zig").SourceMedia;
const Platform = @import("platform.zig").Platform;

const log = std.log.scoped(.frameDecoder);

/// Manages video frame decoding and GPU resource lifetime.
/// Decodes frames on demand using platform-specific decoder (VideoToolbox on macOS).
/// Keeps decoded frame buffers and Metal textures alive between vsync callbacks.
pub const FrameDecoder = struct {
    /// Reference to session (owns playback/monitor)
    session: *Session,

    /// Reference to source media (via session.source)
    source_media: *SourceMedia,

    /// Platform-specific video decoder (VideoToolbox on macOS).
    decoder: videotoolbox.Decoder,

    /// Decoded frame resources - kept alive between vsync callbacks.
    packed_metal_texture: ?metal.MetalTexture,
    decoded_frame_buffer: ?DecodedFrame,
    texture_set_holder: ?videotoolbox.MetalTextureSet,

    pub fn init(platform: *Platform, session: *Session) !FrameDecoder {
        const source_media = session.getCurrentSource();

        // Create platform-specific decoder
        var decoder = try videotoolbox.Decoder.init(
            source_media,
            @ptrCast(platform.window.device_ptr),
        );
        errdefer decoder.deinit();

        log.debug("FrameDecoder initialized for session: {s} ({d}x{d})", .{
            source_media.file_name,
            source_media.resolution.width,
            source_media.resolution.height,
        });

        return .{
            .session = session,
            .source_media = source_media,
            .decoder = decoder,
            .decoded_frame_buffer = null,
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
