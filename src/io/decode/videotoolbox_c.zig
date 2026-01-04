const std = @import("std");

// Manual C API declarations for VideoToolbox/CoreMedia/CoreVideo
// Note: @cImport doesn't work - Apple headers are too complex for Zig's translator
// Using manual extern declarations is the recommended approach for Apple frameworks

// ============================================================================
// Opaque pointer types
// ============================================================================
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
pub const CFArrayRef = ?*opaque {};
pub const CFNumberRef = ?*opaque {};
pub const CFTypeRef = ?*opaque {};
pub const MTLDeviceRef = ?*opaque {};
pub const MTLTextureRef = ?*opaque {};

// ============================================================================
// Basic types
// ============================================================================
pub const OSStatus = i32;
pub const CMItemCount = isize;
pub const FourCharCode = u32;
pub const Boolean = u8;
pub const CFIndex = isize;
pub const CFTypeID = usize;

// ============================================================================
// Common CoreFoundation constants
// ============================================================================
pub const kCFAllocatorDefault: CFAllocatorRef = null;
pub const kCFAllocatorNull: CFAllocatorRef = null;

// ============================================================================
// CMTime structure (from CMTime.h)
// ============================================================================
pub const CMTime = extern struct {
    value: i64,
    timescale: i32,
    flags: u32,
    epoch: i64,
};

pub const CMTimeFlags = enum(u32) {
    kCMTimeFlags_Valid = 1 << 0,
    kCMTimeFlags_HasBeenRounded = 1 << 1,
    kCMTimeFlags_PositiveInfinity = 1 << 2,
    kCMTimeFlags_NegativeInfinity = 1 << 3,
    kCMTimeFlags_Indefinite = 1 << 4,
};

// CMSampleTimingInfo structure
pub const CMSampleTimingInfo = extern struct {
    duration: CMTime,
    presentationTimeStamp: CMTime,
    decodeTimeStamp: CMTime,
};

// ============================================================================
// Codec types (from CMFormatDescription.h)
// ============================================================================
pub const kCMVideoCodecType_AppleProRes422 = @as(FourCharCode, @bitCast([4]u8{ 'a', 'p', 'c', 'n' }));
pub const kCMVideoCodecType_AppleProRes422HQ = @as(FourCharCode, @bitCast([4]u8{ 'a', 'p', 'c', 'h' }));
pub const kCMVideoCodecType_AppleProRes4444 = @as(FourCharCode, @bitCast([4]u8{ 'a', 'p', '4', 'h' }));
pub const kCMVideoCodecType_AppleProRes422LT = @as(FourCharCode, @bitCast([4]u8{ 'a', 'p', 'c', 's' }));
pub const kCMVideoCodecType_AppleProRes422Proxy = @as(FourCharCode, @bitCast([4]u8{ 'a', 'p', 'c', 'o' }));

// ============================================================================
// CVPixelBuffer types (from CVPixelBuffer.h)
// ============================================================================
pub const kCVPixelFormatType_32BGRA = 0x42475241; // 'BGRA'
pub const kCVPixelFormatType_32ARGB = 0x41524742; // 'ARGB'
pub const kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange = 0x34323076; // '420v'
pub const kCVPixelFormatType_420YpCbCr8BiPlanarFullRange = 0x34323066; // '420f'

// CVPixelBuffer property keys
pub const kCVPixelBufferPixelFormatTypeKey: CFStringRef = @ptrFromInt(0); // Will be filled by CF at runtime
pub const kCVPixelBufferWidthKey: CFStringRef = @ptrFromInt(0);
pub const kCVPixelBufferHeightKey: CFStringRef = @ptrFromInt(0);
pub const kCVPixelBufferMetalCompatibilityKey: CFStringRef = @ptrFromInt(0);

// ============================================================================
// VTDecompressionSession property keys
// ============================================================================
pub const kVTDecompressionPropertyKey_PixelBufferPool: CFStringRef = @ptrFromInt(0);
pub const kVTDecompressionPropertyKey_OutputPoolRequestedMinimumBufferCount: CFStringRef = @ptrFromInt(0);
pub const kVTDecompressionPropertyKey_RealTime: CFStringRef = @ptrFromInt(0);
pub const kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: CFStringRef = @ptrFromInt(0);
pub const kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: CFStringRef = @ptrFromInt(0);

// ============================================================================
// VideoToolbox - VTDecompressionSession functions
// ============================================================================

pub extern "c" fn VTDecompressionSessionCreate(
    allocator: CFAllocatorRef,
    videoFormatDescription: CMVideoFormatDescriptionRef,
    videoDecoderSpecification: CFDictionaryRef,
    destinationImageBufferAttributes: CFDictionaryRef,
    outputCallback: ?*const VTDecompressionOutputCallbackRecord,
    decompressionSessionOut: *VTDecompressionSessionRef,
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

pub extern "c" fn VTDecompressionSessionInvalidate(
    session: VTDecompressionSessionRef,
) void;

pub extern "c" fn VTDecompressionSessionFinishDelayedFrames(
    session: VTDecompressionSessionRef,
) OSStatus;

pub extern "c" fn VTDecompressionSessionCanAcceptFormatDescription(
    session: VTDecompressionSessionRef,
    formatDescription: CMVideoFormatDescriptionRef,
) Boolean;

pub extern "c" fn VTDecompressionSessionGetTypeID() CFTypeID;

pub extern "c" fn VTDecompressionSessionCopyBlackPixelBuffer(
    session: VTDecompressionSessionRef,
    pixelBufferOut: *CVPixelBufferRef,
) OSStatus;

pub extern "c" fn VTIsHardwareDecodeSupported(
    codecType: FourCharCode,
) Boolean;

// VTDecompressionOutputCallback
pub const VTDecompressionOutputCallback = *const fn (
    decompressionOutputRefCon: ?*anyopaque,
    sourceFrameRefCon: ?*anyopaque,
    status: OSStatus,
    infoFlags: u32,
    imageBuffer: CVPixelBufferRef,
    presentationTimeStamp: CMTime,
    presentationDuration: CMTime,
) callconv(.c) void;

pub const VTDecompressionOutputCallbackRecord = extern struct {
    decompressionOutputCallback: VTDecompressionOutputCallback,
    decompressionOutputRefCon: ?*anyopaque,
};

// ============================================================================
// CoreMedia - CMFormatDescription functions
// ============================================================================

pub extern "c" fn CMVideoFormatDescriptionCreate(
    allocator: CFAllocatorRef,
    codecType: FourCharCode,
    width: i32,
    height: i32,
    extensions: CFDictionaryRef,
    formatDescriptionOut: *CMVideoFormatDescriptionRef,
) OSStatus;

pub extern "c" fn CMVideoFormatDescriptionGetDimensions(
    videoDesc: CMVideoFormatDescriptionRef,
) extern struct { width: i32, height: i32 };

pub extern "c" fn CMFormatDescriptionGetMediaType(
    desc: CMVideoFormatDescriptionRef,
) FourCharCode;

pub extern "c" fn CMFormatDescriptionGetMediaSubType(
    desc: CMVideoFormatDescriptionRef,
) FourCharCode;

// ============================================================================
// CoreMedia - CMBlockBuffer functions
// ============================================================================

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

pub extern "c" fn CMBlockBufferGetDataLength(
    theBuffer: CMBlockBufferRef,
) usize;

pub extern "c" fn CMBlockBufferGetDataPointer(
    theBuffer: CMBlockBufferRef,
    offset: usize,
    lengthAtOffsetOut: ?*usize,
    totalLengthOut: ?*usize,
    dataPointerOut: *?*anyopaque,
) OSStatus;

// ============================================================================
// CoreMedia - CMSampleBuffer functions
// ============================================================================

pub extern "c" fn CMSampleBufferCreate(
    allocator: CFAllocatorRef,
    dataBuffer: CMBlockBufferRef,
    dataReady: Boolean,
    makeDataReadyCallback: ?*const anyopaque,
    makeDataReadyRefcon: ?*anyopaque,
    formatDescription: CMVideoFormatDescriptionRef,
    numSamples: CMItemCount,
    numSampleTimingEntries: CMItemCount,
    sampleTimingArray: ?*const CMSampleTimingInfo,
    numSampleSizeEntries: CMItemCount,
    sampleSizeArray: ?*const usize,
    sampleBufferOut: *CMSampleBufferRef,
) OSStatus;

pub extern "c" fn CMSampleBufferGetImageBuffer(
    sbuf: CMSampleBufferRef,
) CVPixelBufferRef;

pub extern "c" fn CMSampleBufferGetFormatDescription(
    sbuf: CMSampleBufferRef,
) CMVideoFormatDescriptionRef;

pub extern "c" fn CMSampleBufferGetPresentationTimeStamp(
    sbuf: CMSampleBufferRef,
) CMTime;

pub extern "c" fn CMSampleBufferGetDuration(
    sbuf: CMSampleBufferRef,
) CMTime;

pub extern "c" fn CMSampleBufferIsValid(
    sbuf: CMSampleBufferRef,
) Boolean;

// ============================================================================
// CoreMedia - CMTime functions
// ============================================================================

pub extern "c" fn CMTimeMake(
    value: i64,
    timescale: i32,
) CMTime;

pub extern "c" fn CMTimeGetSeconds(
    time: CMTime,
) f64;

pub extern "c" fn CMTimeCompare(
    time1: CMTime,
    time2: CMTime,
) i32;

pub extern "c" fn CMTimeAdd(
    addend1: CMTime,
    addend2: CMTime,
) CMTime;

pub extern "c" fn CMTimeSubtract(
    minuend: CMTime,
    subtrahend: CMTime,
) CMTime;

// CMTime constants
pub const kCMTimeInvalid = CMTime{
    .value = 0,
    .timescale = 0,
    .flags = 0,
    .epoch = 0,
};

pub const kCMTimeZero = CMTime{
    .value = 0,
    .timescale = 1,
    .flags = @intFromEnum(CMTimeFlags.kCMTimeFlags_Valid),
    .epoch = 0,
};

// ============================================================================
// CoreVideo - CVPixelBuffer functions
// ============================================================================

pub extern "c" fn CVPixelBufferGetWidth(
    pixelBuffer: CVPixelBufferRef,
) usize;

pub extern "c" fn CVPixelBufferGetHeight(
    pixelBuffer: CVPixelBufferRef,
) usize;

pub extern "c" fn CVPixelBufferGetPixelFormatType(
    pixelBuffer: CVPixelBufferRef,
) u32;

pub extern "c" fn CVPixelBufferLockBaseAddress(
    pixelBuffer: CVPixelBufferRef,
    lockFlags: u64,
) i32;

pub extern "c" fn CVPixelBufferUnlockBaseAddress(
    pixelBuffer: CVPixelBufferRef,
    unlockFlags: u64,
) i32;

pub extern "c" fn CVPixelBufferGetBaseAddress(
    pixelBuffer: CVPixelBufferRef,
) ?*anyopaque;

pub extern "c" fn CVPixelBufferGetBytesPerRow(
    pixelBuffer: CVPixelBufferRef,
) usize;

// ============================================================================
// CoreVideo - CVMetalTextureCache functions
// ============================================================================

pub extern "c" fn CVMetalTextureCacheCreate(
    allocator: CFAllocatorRef,
    cacheAttributes: CFDictionaryRef,
    metalDevice: MTLDeviceRef,
    textureAttributes: CFDictionaryRef,
    cacheOut: *CVMetalTextureCacheRef,
) i32;

pub extern "c" fn CVMetalTextureCacheCreateTextureFromImage(
    allocator: CFAllocatorRef,
    textureCache: CVMetalTextureCacheRef,
    sourceImage: CVPixelBufferRef,
    textureAttributes: CFDictionaryRef,
    pixelFormat: u64,
    width: usize,
    height: usize,
    planeIndex: usize,
    textureOut: *CVMetalTextureRef,
) i32;

pub extern "c" fn CVMetalTextureGetTexture(
    image: CVMetalTextureRef,
) MTLTextureRef;

pub extern "c" fn CVMetalTextureCacheFlush(
    textureCache: CVMetalTextureCacheRef,
    options: u64,
) void;

// ============================================================================
// CoreFoundation - CFType functions
// ============================================================================

pub extern "c" fn CFRelease(cf: ?*anyopaque) void;
pub extern "c" fn CFRetain(cf: ?*const anyopaque) ?*const anyopaque;
pub extern "c" fn CFGetTypeID(cf: CFTypeRef) CFTypeID;

// ============================================================================
// CoreFoundation - CFDictionary functions
// ============================================================================

pub extern "c" fn CFDictionaryCreate(
    allocator: CFAllocatorRef,
    keys: ?*const ?*const anyopaque,
    values: ?*const ?*const anyopaque,
    numValues: CFIndex,
    keyCallBacks: ?*const anyopaque,
    valueCallBacks: ?*const anyopaque,
) CFDictionaryRef;

pub extern "c" fn CFDictionaryGetValue(
    theDict: CFDictionaryRef,
    key: ?*const anyopaque,
) ?*const anyopaque;

// ============================================================================
// CoreFoundation - CFNumber functions
// ============================================================================

pub extern "c" fn CFNumberCreate(
    allocator: CFAllocatorRef,
    theType: CFIndex,
    valuePtr: ?*const anyopaque,
) CFNumberRef;

pub const kCFNumberSInt32Type: CFIndex = 3;
pub const kCFNumberFloat64Type: CFIndex = 13;

// ============================================================================
// OSStatus error codes
// ============================================================================
pub const noErr: OSStatus = 0;
pub const kVTInvalidSessionErr: OSStatus = -12903;
pub const kVTVideoDecoderBadDataErr: OSStatus = -12909;
pub const kVTVideoDecoderUnsupportedDataFormatErr: OSStatus = -12910;
pub const kVTVideoDecoderMalfunctionErr: OSStatus = -12911;
pub const kVTVideoEncoderMalfunctionErr: OSStatus = -12912;
pub const kVTVideoDecoderNotAvailableNowErr: OSStatus = -12913;
pub const kVTImageRotationNotSupportedErr: OSStatus = -12914;
pub const kVTVideoEncoderNotAvailableNowErr: OSStatus = -12915;

pub fn main() !void {
    std.debug.print("Testing VideoToolbox extern declarations...\n", .{});

    // Test that we can reference the function pointer
    std.debug.print("VTDecompressionSessionCreate address: {*}\n", .{&VTDecompressionSessionCreate});

    std.debug.print("Extern declarations compiled successfully!\n", .{});
}
