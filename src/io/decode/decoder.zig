const std = @import("std");

const Allocator = std.mem.Allocator;

pub const DecodedFrame = struct {
    /// Opaque platform handle (CVPixelBufferRef on macOS, AVFrame* on Linux)
    platform_handle: *anyopaque,

    /// Frame metadata
    width: usize,
    height: usize,
    compressed_size: usize,
    decoded_size: usize,

    /// Cleanup function — each platform implements its own
    deinit_fn: *const fn (*anyopaque) void,

    pub fn deinit(self: *DecodedFrame) void {
        self.deinit_fn(self.platform_handle);
    }
};

pub const Decoder = struct {
    impl: *anyopaque,

    decode_frame_fn: *const fn (
        impl: *anyopaque,
        frame_idx: usize,
        allocator: Allocator,

        // INFO: Could return an error set later on...
        //   pub const DecodeError = error{
        // DecodeFailed,
        // FrameNotFound,
        // InvalidFrameIndex,
        // etc

    ) anyerror!DecodedFrame,

    deinit_fn: *const fn (*anyopaque) void,

    pub fn deinit(self: *Decoder) void {
        self.deinit_fn(self.impl);
    }

    pub fn decodeFrame(
        self: *Decoder,
        frame_idx: usize,
        allocator: Allocator,
    ) !DecodedFrame {
        return self.decode_frame_fn(self.impl, frame_idx, allocator);
    }
};
