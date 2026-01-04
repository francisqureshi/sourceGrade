const std = @import("std");

// Manual C API declarations for VideoToolbox/CoreMedia
// This avoids the complexity of @cImport with Apple's nested headers

// Opaque pointer types
pub const VTDecompressionSessionRef = ?*opaque {};
pub const CMVideoFormatDescriptionRef = ?*opaque {};
pub const CMSampleBufferRef = ?*opaque {};
pub const CMBlockBufferRef = ?*opaque {};
pub const CVPixelBufferRef = ?*opaque {};
pub const CVMetalTextureCacheRef = ?*opaque {};
pub const CVMetalTextureRef = ?*opaque {};
pub const CFAllocatorRef = ?*opaque {};
pub const CFDictionaryRef = ?*opaque {};
pub const CFStringRef = ?*opaque {};

// Basic types
pub const OSStatus = i32;
pub const CMItemCount = isize;
pub const FourCharCode = u32;

// CMTime structure (from CMTime.h)
pub const CMTime = extern struct {
    value: i64,
    timescale: i32,
    flags: u32,
    epoch: i64,
};

// Codec types (from CMFormatDescription.h)
pub const kCMVideoCodecType_AppleProRes422 = @as(FourCharCode, @bitCast([4]u8{ 'a', 'p', 'c', 'n' }));
pub const kCMVideoCodecType_AppleProRes422HQ = @as(FourCharCode, @bitCast([4]u8{ 'a', 'p', 'c', 'h' }));
pub const kCMVideoCodecType_AppleProRes4444 = @as(FourCharCode, @bitCast([4]u8{ 'a', 'p', '4', 'h' }));

// Pixel format types (from CVPixelBuffer.h)
pub const kCVPixelFormatType_32BGRA = 0x42475241; // 'BGRA'

// Extern function declarations
// Note: VTGetTypeID doesn't exist in VideoToolbox - removed

pub extern "c" fn CMVideoFormatDescriptionCreate(
    allocator: CFAllocatorRef,
    codecType: FourCharCode,
    width: i32,
    height: i32,
    extensions: CFDictionaryRef,
    formatDescriptionOut: *CMVideoFormatDescriptionRef,
) OSStatus;

pub extern "c" fn VTDecompressionSessionCreate(
    allocator: CFAllocatorRef,
    videoFormatDescription: CMVideoFormatDescriptionRef,
    videoDecoderSpecification: CFDictionaryRef,
    destinationImageBufferAttributes: CFDictionaryRef,
    outputCallback: ?*const anyopaque,
    decompressionSessionOut: *VTDecompressionSessionRef,
) OSStatus;

pub extern "c" fn CMBlockBufferCreateWithMemoryBlock(
    structureAllocator: CFAllocatorRef,
    memoryBlock: ?*anyopaque,
    blockLength: usize,
    blockAllocator: CFAllocatorRef,
    customBlockSource: ?*const anyopaque,
    offsetToData: usize,
    dataLength: usize,
    flags: u32,
    blockBufferOut: *CMBlockBufferRef,
) OSStatus;

pub extern "c" fn CMSampleBufferCreate(
    allocator: CFAllocatorRef,
    dataBuffer: CMBlockBufferRef,
    dataReady: bool,
    makeDataReadyCallback: ?*const anyopaque,
    makeDataReadyRefcon: ?*anyopaque,
    formatDescription: CMVideoFormatDescriptionRef,
    numSamples: CMItemCount,
    numSampleTimingEntries: CMItemCount,
    sampleTimingArray: ?*const anyopaque,
    numSampleSizeEntries: CMItemCount,
    sampleSizeArray: ?*const usize,
    sampleBufferOut: *CMSampleBufferRef,
) OSStatus;

pub extern "c" fn VTDecompressionSessionDecodeFrame(
    session: VTDecompressionSessionRef,
    sampleBuffer: CMSampleBufferRef,
    decodeFlags: u32,
    sourceFrameRefCon: ?*anyopaque,
    infoFlagsOut: ?*u32,
) OSStatus;

pub extern "c" fn VTDecompressionSessionWaitForAsynchronousFrames(
    session: VTDecompressionSessionRef,
) OSStatus;

pub extern "c" fn CFRelease(cf: ?*anyopaque) void;
pub extern "c" fn CFRetain(cf: ?*const anyopaque) ?*const anyopaque;

pub fn main() !void {
    std.debug.print("Testing VideoToolbox extern declarations...\n", .{});

    // Test that we can reference the function pointer
    std.debug.print("VTDecompressionSessionCreate address: {*}\n", .{&VTDecompressionSessionCreate});

    std.debug.print("Extern declarations compiled successfully!\n", .{});
}
