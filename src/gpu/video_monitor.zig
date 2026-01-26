const std = @import("std");
const metal = @import("metal");
const imgui = @import("../gui/imgui.zig");

const media = @import("../io/media.zig");
const vtb = @import("../io/decode/vtb_decode.zig");

const rndr = @import("renderer.zig");

pub const MonitorResult = enum {
    ok,
    decoded_new_frame,
    decode_failed,
    texture_failed,
};

pub const VideoMonitor = struct {
    ctx: *rndr.RenderContext,
    source_media: *media.SourceMedia,

    ctrl_playback: f32,
    ctrl_playback_speed: f32, // 1.0 = normal speed, 0.5 = half speed, 2.0 = double speed

    timer: std.time.Timer,
    playback_time_ns: u64,
    base_frame_duration_ns: u64,
    last_frame_time_ns: u64,
    current_frame_index: usize,
    last_decoded_frame_index: ?usize,

    // Video texture holders must persist across frames
    // These keep the CVPixelBuffer and Metal textures alive between decode and present
    packed_metal_texture: ?metal.MetalTexture,
    decoded_frame_holder: ?vtb.DecodedFrame,
    texture_set_holder: ?vtb.MetalTextureSet,

    pub fn init(ctx: *rndr.RenderContext, source_media: *media.SourceMedia) !VideoMonitor {
        const timer = try std.time.Timer.start();
        const base_frame_duration_ns: u64 = @intFromFloat(std.time.ns_per_s / source_media.frame_rate_float);

        return .{
            .ctx = ctx,
            .source_media = source_media,

            .ctrl_playback = 0.0,
            .ctrl_playback_speed = 1.0,
            .timer = timer,

            .base_frame_duration_ns = base_frame_duration_ns,
            .playback_time_ns = 0,
            .last_frame_time_ns = 0,

            .current_frame_index = 0,
            .last_decoded_frame_index = null,

            .packed_metal_texture = null,
            .decoded_frame_holder = null,
            .texture_set_holder = null,
        };
    }

    pub fn monitor(self: *VideoMonitor) MonitorResult {
        const ui_frame_delta_ns = self.timer.lap();
        // on macbook pro with 120 hz this is
        // - ~3ms
        // - ~8.5ms
        // - ~8.5ms
        // - ~10ms
        // - ~11-12ms
        //  About 40ms for 25fps playback but with triple buffered ui vsync of 8.3ms
        //  means 40ms is every 4.8 vsyncs..
        // std.debug.print("frame delta: {}ns\n", .{delta_ns});

        if (self.ctrl_playback != 0.0) {
            // Accumulate frame_delta_ns
            self.playback_time_ns += @as(u64, @intFromFloat(@as(f64, @floatFromInt(ui_frame_delta_ns)) * self.ctrl_playback_speed));
        }

        // Video frame timing - decode and create Metal textures from YCbCr
        const sm = self.source_media;
        const time_since_last_frame_ns = self.playback_time_ns - self.last_frame_time_ns;

        // Adjust frame duration by playback speed
        const frame_duration_ns = if (self.ctrl_playback_speed > 0.0)
            @as(u64, @intFromFloat(@as(f64, @floatFromInt(self.base_frame_duration_ns)) / self.ctrl_playback_speed))
        else
            self.base_frame_duration_ns;

        // Should we decode? Yes if:
        // - Frame index changed (first frame, seek, or playback advanced)
        // - OR we're playing and enough time has passed
        const frame_changed = self.last_decoded_frame_index == null or self.last_decoded_frame_index.? != self.current_frame_index;
        const advance = self.ctrl_playback != 0.0 and frame_duration_ns > 0 and time_since_last_frame_ns >= frame_duration_ns;
        const should_decode = frame_changed or advance;

        if (should_decode) {
            // Clean up previous frame resources before next decode
            if (self.decoded_frame_holder) |*df| {
                df.deinit();
                self.decoded_frame_holder = null;
            }
            if (self.texture_set_holder) |*ts| {
                ts.deinit();
                self.texture_set_holder = null;
            }

            std.debug.print("Decoding frame {} (last={?}, advance={})\n", .{ self.current_frame_index, self.last_decoded_frame_index, advance });
            const decoded_frame = sm.decodeSourceFrame(self.current_frame_index, @ptrCast(self.ctx.device_ptr)) catch |err| {
                std.debug.print("❌ Failed to decode frame: {}\n", .{err});
                return .decode_failed;
            };
            self.decoded_frame_holder = decoded_frame; // Keep alive until end of loop

            // Create Metal texture from packed AYUV buffer (y416 format)
            var texture_set = sm.decoder.?.createMetalTextures(decoded_frame.pixel_buffer) catch |err| {
                std.debug.print("❌ Failed to create Metal textures: {}\n", .{err});
                return .texture_failed;
            };
            self.texture_set_holder = texture_set; // Keep alive until end of loop

            // Extract MTLTexture handle (single packed texture for y416)
            const mtl_tex = texture_set.getMetalTexture();
            self.packed_metal_texture = metal.MetalTexture.initFromPtr(mtl_tex);

            // Advance to next frame only if playing and time elapsed
            if (advance) {
                if (self.ctrl_playback > 0.0) {
                    // Advance Forward
                    self.current_frame_index = (self.current_frame_index + 1) % @as(usize, @intCast(sm.duration_in_frames));
                } else if (self.ctrl_playback < 0.0) {
                    // Advance Backward (wrap at 0)
                    self.current_frame_index = if (self.current_frame_index == 0)
                        @as(usize, @intCast(sm.duration_in_frames - 1))
                    else
                        self.current_frame_index - 1;
                }
                self.last_frame_time_ns = self.playback_time_ns;
            }

            // Mark this frame as decoded
            self.last_decoded_frame_index = self.current_frame_index;
            return .decoded_new_frame;
        }
        return .ok;
    }
};
