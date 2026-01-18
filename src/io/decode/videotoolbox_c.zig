const std = @import("std");

// Manual C API declarations for VideoToolbox/CoreMedia/CoreVideo
// Note: @cImport doesn't work - Apple headers are too complex for Zig's translator
// Using manual extern declarations is the recommended approach for Apple frameworks

// ============================================================================
// Opaque pointer types
// ============================================================================

/// VideoToolbox decompression session - hardware video decoder instance
pub const VTDecompressionSessionRef = ?*opaque {};

/// CoreMedia format description - describes video codec, dimensions, and format details
pub const CMVideoFormatDescriptionRef = ?*opaque {};

/// CoreMedia sample buffer - container for compressed video frame + timing info
pub const CMSampleBufferRef = ?*opaque {};

/// CoreMedia block buffer - wrapper around raw compressed frame bytes
pub const CMBlockBufferRef = ?*opaque {};

/// CoreVideo pixel buffer - decoded pixel data (GPU-backed, ref-counted)
pub const CVPixelBufferRef = ?*opaque {};

/// CoreVideo Metal texture cache - converts CVPixelBuffer to Metal textures
pub const CVMetalTextureCacheRef = ?*opaque {};

/// CoreVideo Metal texture - GPU texture created from CVPixelBuffer
pub const CVMetalTextureRef = ?*opaque {};

/// CoreFoundation allocator - memory allocator for CF objects
pub const CFAllocatorRef = ?*opaque {};

/// CoreFoundation dictionary - key-value collection
pub const CFDictionaryRef = ?*opaque {};

/// CoreFoundation string - immutable string object
pub const CFStringRef = ?*opaque {};

/// CoreFoundation array - ordered collection
pub const CFArrayRef = ?*opaque {};

/// CoreFoundation number - boxed numeric value
pub const CFNumberRef = ?*opaque {};

/// CoreFoundation type - base type for all CF objects
pub const CFTypeRef = ?*opaque {};

/// CoreVideo buffer reference - base type for pixel buffers
pub const CVBufferRef = CVPixelBufferRef;

/// Metal device - GPU device handle
pub const MTLDeviceRef = ?*opaque {};

/// Metal texture - GPU texture resource
pub const MTLTextureRef = ?*opaque {};

// ============================================================================
// Metal pixel format constants
// ============================================================================

/// Metal pixel format type (maps to MTLPixelFormat enum values)
pub const MTLPixelFormat = u64;

/// 16-bit single channel normalized (0.0-1.0) - used for Y and Alpha planes
pub const MTLPixelFormatR16Unorm: MTLPixelFormat = 55;

/// 16-bit single channel unsigned integer (TEST for debugging)
pub const MTLPixelFormatR16Uint: MTLPixelFormat = 13;

/// 16-bit dual channel normalized (0.0-1.0) - used for CbCr plane
pub const MTLPixelFormatRG16Unorm: MTLPixelFormat = 65;

/// Try alternate format - maybe the enum value is wrong?
pub const MTLPixelFormatRG16Unorm_Alt: MTLPixelFormat = 105;

/// 16-bit dual channel signed normalized (-1.0 to 1.0)
pub const MTLPixelFormatRG16Snorm: MTLPixelFormat = 66;

/// 8-bit dual channel normalized (0.0-1.0)
pub const MTLPixelFormatRG8Unorm: MTLPixelFormat = 30;

/// 8-bit single channel normalized (0.0-1.0)
pub const MTLPixelFormatR8Unorm: MTLPixelFormat = 10;

/// 64-bit RGBA normalized (16 bits per component) - for packed y416/AYUV
pub const MTLPixelFormatRGBA16Unorm: MTLPixelFormat = 85;

/// 32-bit BGRA normalized (8 bits per component) - common display format
pub const MTLPixelFormatBGRA8Unorm: MTLPixelFormat = 80;

// ============================================================================
// Basic types
// ============================================================================

/// Apple API error/status code (0 = success, negative = error)
pub const OSStatus = i32;

/// CoreMedia item count (signed to allow -1 for "unknown")
pub const CMItemCount = isize;

/// Four-character codec identifier (e.g., 'ap4h' for ProRes 4444)
pub const FourCharCode = u32;

/// C-style boolean (0 = false, non-zero = true)
pub const Boolean = u8;

/// CoreFoundation index/count type
pub const CFIndex = isize;

/// CoreFoundation type identifier (unique ID for each CF class)
pub const CFTypeID = usize;

// ============================================================================
// Common CoreFoundation constants
// ============================================================================

/// Default CF allocator (uses malloc/free under the hood)
pub const kCFAllocatorDefault: CFAllocatorRef = null;

/// Null allocator - caller manages memory (use with pre-allocated buffers)
pub const kCFAllocatorNull: CFAllocatorRef = null;

/// CFBoolean true value (exported symbol from CoreFoundation framework)
pub extern "c" var kCFBooleanTrue: CFTypeRef;

/// CFBoolean false value (exported symbol from CoreFoundation framework)
pub extern "c" var kCFBooleanFalse: CFTypeRef;

// ============================================================================
// CMTime structure (from CMTime.h)
// ============================================================================

/// CoreMedia time representation (rational number: value/timescale seconds)
/// Example: frame 0 at 24fps = CMTime{.value=0, .timescale=24, .flags=1, .epoch=0}
pub const CMTime = extern struct {
    /// Numerator of the time value
    value: i64,
    /// Denominator of the time value (e.g., 24 for 24fps, 1000 for milliseconds)
    timescale: i32,
    /// Flags indicating validity, infinity, etc.
    flags: u32,
    /// Epoch for discontinuities (usually 0)
    epoch: i64,
};

/// Flags for CMTime validity and special states
pub const CMTimeFlags = enum(u32) {
    /// Time is valid and can be used
    kCMTimeFlags_Valid = 1 << 0,
    /// Time has been rounded (precision loss)
    kCMTimeFlags_HasBeenRounded = 1 << 1,
    /// Time represents positive infinity
    kCMTimeFlags_PositiveInfinity = 1 << 2,
    /// Time represents negative infinity
    kCMTimeFlags_NegativeInfinity = 1 << 3,
    /// Time is indefinite (unknown duration)
    kCMTimeFlags_Indefinite = 1 << 4,
};

/// Timing information for a video sample (frame)
pub const CMSampleTimingInfo = extern struct {
    /// How long the sample should be displayed
    duration: CMTime,
    /// When the sample should be displayed (PTS)
    presentationTimeStamp: CMTime,
    /// When the sample should be decoded (DTS, usually same as PTS for intra-frame codecs)
    decodeTimeStamp: CMTime,
};

// ============================================================================
// Codec types (from CMFormatDescription.h)
// ============================================================================

/// Apple ProRes 422 codec ('apcn') - standard quality
pub const kCMVideoCodecType_AppleProRes422 = @as(FourCharCode, @bitCast([4]u8{ 'a', 'p', 'c', 'n' }));

/// Apple ProRes 422 HQ codec ('apch') - higher quality
pub const kCMVideoCodecType_AppleProRes422HQ = @as(FourCharCode, @bitCast([4]u8{ 'a', 'p', 'c', 'h' }));

/// Apple ProRes 4444 codec ('ap4h') - highest quality with alpha support
pub const kCMVideoCodecType_AppleProRes4444 = @as(FourCharCode, @bitCast([4]u8{ 'a', 'p', '4', 'h' }));

/// Apple ProRes 422 LT codec ('apcs') - light, lower bitrate
pub const kCMVideoCodecType_AppleProRes422LT = @as(FourCharCode, @bitCast([4]u8{ 'a', 'p', 'c', 's' }));

/// Apple ProRes 422 Proxy codec ('apco') - lowest bitrate for offline editing
pub const kCMVideoCodecType_AppleProRes422Proxy = @as(FourCharCode, @bitCast([4]u8{ 'a', 'p', 'c', 'o' }));

// ============================================================================
// CVPixelBuffer types (from CVPixelBuffer.h)
// ============================================================================

/// 32-bit BGRA pixel format (8 bits per component) - most common for display
pub const kCVPixelFormatType_32BGRA = 0x42475241; // 'BGRA'

/// 32-bit ARGB pixel format (8 bits per component)
pub const kCVPixelFormatType_32ARGB = 0x41524742; // 'ARGB'

/// 64-bit ARGB pixel format (16 bits per component) - preserves ProRes 4444 bit depth
pub const kCVPixelFormatType_64ARGB = 0x62363461; // 'b64a'

/// 128-bit RGBA float (32-bit float per component) - native float format
pub const kCVPixelFormatType_128RGBAFloat = 0x52474261; //RGBf' (note: check actual FourCC)

/// 4:4:4:4 AYpCbCr 16-bit packed (16 bits per component)
/// Component order: A Y' Cb Cr in single buffer
/// Note: May crash during ProRes decode - use tri-planar format instead
pub const kCVPixelFormatType_4444AYpCbCr16 = 0x76343136; // 'v416'

/// 4:4:4 YpCbCr 16-bit tri-planar with 16-bit alpha ✨ WORKS for ProRes 4444!
/// Plane 0: Y (luma), Plane 1: CbCr interleaved, Plane 2: A (alpha)
/// 16 bits per component, video range Y'CbCr, full range alpha
/// Preserves full ProRes 4444 bit depth (12-bit RGB + 16-bit alpha)
/// Total: 64 bits per pixel (8 bytes), ~96MB for 4K frame
pub const kCVPixelFormatType_444YpCbCr16VideoRange_16A_TriPlanar = 0x73346173; // 'sa4s'

/// 4:4:4 YpCbCr 16-bit bi-planar (video range) - FFmpeg P416 format
/// Plane 0: Y, Plane 1: CbCr interleaved (no alpha)
pub const kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange = 0x70343136; // 'p416'

/// 4:2:0 YCbCr bi-planar (video range) - efficient for video
pub const kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange = 0x34323076; // '420v'

/// 4:2:0 YCbCr bi-planar (full range) - full color range
pub const kCVPixelFormatType_420YpCbCr8BiPlanarFullRange = 0x34323066; // '420f'

/// CVPixelBuffer attribute key for pixel format type (exported from CoreVideo framework)
pub extern "c" var kCVPixelBufferPixelFormatTypeKey: CFStringRef;

/// CVPixelBuffer attribute key for width (exported from CoreVideo framework)
pub extern "c" var kCVPixelBufferWidthKey: CFStringRef;

/// CVPixelBuffer attribute key for height (exported from CoreVideo framework)
pub extern "c" var kCVPixelBufferHeightKey: CFStringRef;

/// CVPixelBuffer attribute key for Metal compatibility (exported from CoreVideo framework)
pub extern "c" var kCVPixelBufferMetalCompatibilityKey: CFStringRef;

// ============================================================================
// VTDecompressionSession property keys - exported symbols from VideoToolbox framework
// ============================================================================

/// Key to get the pixel buffer pool used by the decompression session
pub extern "c" var kVTDecompressionPropertyKey_PixelBufferPool: CFStringRef;

/// Key to request minimum number of buffers in the output pool
pub extern "c" var kVTDecompressionPropertyKey_OutputPoolRequestedMinimumBufferCount: CFStringRef;

/// Key to enable real-time decoding mode (prioritizes speed over quality)
pub extern "c" var kVTDecompressionPropertyKey_RealTime: CFStringRef;

/// Key to enable hardware-accelerated decoding (if available, falls back to software)
pub extern "c" var kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: CFStringRef;

/// Key to require hardware-accelerated decoding (fails if hardware unavailable)
pub extern "c" var kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: CFStringRef;

// ============================================================================
// VideoToolbox - VTDecompressionSession functions
// ============================================================================

/// Creates a decompression session for decoding compressed video frames
/// Registers professional video workflow decoders (ProRes, etc.)
/// Call once at app startup to access specialized Pro video decoders
/// Without this, ProRes may be converted to other formats automatically
/// Returns: noErr (0) on success
pub extern "c" fn VTRegisterProfessionalVideoWorkflowVideoDecoders() OSStatus;

/// Returns: noErr (0) on success, negative error code on failure
/// Note: Call VTDecompressionSessionInvalidate() then CFRelease() when done
pub extern "c" fn VTDecompressionSessionCreate(
    allocator: CFAllocatorRef,
    videoFormatDescription: CMVideoFormatDescriptionRef,
    videoDecoderSpecification: CFDictionaryRef,
    destinationImageBufferAttributes: CFDictionaryRef,
    outputCallback: ?*const VTDecompressionOutputCallbackRecord,
    decompressionSessionOut: *VTDecompressionSessionRef,
) OSStatus;

/// Decodes a compressed video frame asynchronously
/// Returns immediately - decoded frame arrives in callback
/// Returns: noErr (0) on success, negative error code on failure
pub extern "c" fn VTDecompressionSessionDecodeFrame(
    session: VTDecompressionSessionRef,
    sampleBuffer: CMSampleBufferRef,
    decodeFlags: u32,
    sourceFrameRefCon: ?*anyopaque,
    infoFlagsOut: ?*u32,
) OSStatus;

/// Blocks until all pending frames have been decoded and callbacks invoked
/// Use this to synchronously wait for decode completion
/// Returns: noErr (0) on success, negative error code on failure
pub extern "c" fn VTDecompressionSessionWaitForAsynchronousFrames(
    session: VTDecompressionSessionRef,
) OSStatus;

/// Invalidates the session (stops accepting new frames, cancels pending work)
/// Must be called before CFRelease() to properly clean up
pub extern "c" fn VTDecompressionSessionInvalidate(
    session: VTDecompressionSessionRef,
) void;

/// Directs the session to finish delayed frames
/// Returns: noErr (0) on success, negative error code on failure
pub extern "c" fn VTDecompressionSessionFinishDelayedFrames(
    session: VTDecompressionSessionRef,
) OSStatus;

/// Checks if the session can decode a different format without recreation
/// Returns: non-zero if compatible, 0 if incompatible
pub extern "c" fn VTDecompressionSessionCanAcceptFormatDescription(
    session: VTDecompressionSessionRef,
    formatDescription: CMVideoFormatDescriptionRef,
) Boolean;

/// Returns the CFTypeID for VTDecompressionSession
pub extern "c" fn VTDecompressionSessionGetTypeID() CFTypeID;

/// Creates a black pixel buffer matching the session's output format
/// Returns: noErr (0) on success, negative error code on failure
pub extern "c" fn VTDecompressionSessionCopyBlackPixelBuffer(
    session: VTDecompressionSessionRef,
    pixelBufferOut: *CVPixelBufferRef,
) OSStatus;

/// Checks if hardware decode is supported for the given codec
/// Returns: non-zero if hardware decode available, 0 if software-only
pub extern "c" fn VTIsHardwareDecodeSupported(
    codecType: FourCharCode,
) Boolean;

/// Copies a dictionary of supported properties for any VT session
/// Works with VTDecompressionSessionRef, VTCompressionSessionRef, etc.
/// Returns: OSStatus (0 on success), outputs dictionary via pointer
pub extern "c" fn VTSessionCopySupportedPropertyDictionary(
    session: ?*anyopaque, // Generic VTSessionRef - can be decompression or compression session
    supportedPropertyDictionaryOut: *CFDictionaryRef,
) OSStatus;

/// Copies the value of a specific property from a VT session
/// Returns: OSStatus (0 on success), outputs property value via pointer (must CFRelease)
pub extern "c" fn VTSessionCopyProperty(
    session: ?*anyopaque, // Generic VTSessionRef
    propertyKey: CFStringRef, // Property key (e.g., kVTDecompressionPropertyKey_SupportedPixelFormatsOrderedByQuality)
    allocator: ?*anyopaque, // Usually null
    propertyValueOut: *?*anyopaque, // Outputs the property value
) OSStatus;

// VTDecompressionSession property keys
pub extern "c" var kVTDecompressionPropertyKey_SupportedPixelFormatsOrderedByQuality: CFStringRef;
pub extern "c" var kVTDecompressionPropertyKey_SupportedPixelFormatsOrderedByPerformance: CFStringRef;

/// Callback function signature for receiving decoded frames
/// Called asynchronously on a background thread when a frame is decoded
/// Must use .c calling convention and be exported
pub const VTDecompressionOutputCallback = *const fn (
    decompressionOutputRefCon: ?*anyopaque, // Context pointer passed through from session creation
    sourceFrameRefCon: ?*anyopaque, // Context pointer passed with each decode call
    status: OSStatus, // Decode status (0 = success)
    infoFlags: u32, // Info about the decode (dropped frames, etc.)
    imageBuffer: CVPixelBufferRef, // Decoded pixel buffer (retain if you need to keep it)
    presentationTimeStamp: CMTime, // PTS of the decoded frame
    presentationDuration: CMTime, // Duration of the decoded frame
) callconv(.c) void;

/// Callback record passed to VTDecompressionSessionCreate
pub const VTDecompressionOutputCallbackRecord = extern struct {
    /// Function to call when frames are decoded
    decompressionOutputCallback: VTDecompressionOutputCallback,
    /// Context pointer passed to every callback invocation
    decompressionOutputRefCon: ?*anyopaque,
};

// ============================================================================
// CoreMedia - CMFormatDescription functions
// ============================================================================

/// CoreFoundation string encoding type
pub const CFStringEncoding = u32;

/// Flavor of image description data (QuickTime, ISOFamily, etc.)
pub const CMImageDescriptionFlavor = CFStringRef;

/// Creates a video format description from codec type and dimensions
/// Returns: noErr (0) on success, negative error code on failure
/// Note: Must CFRelease() when done
pub extern "c" fn CMVideoFormatDescriptionCreate(
    allocator: CFAllocatorRef,
    codecType: FourCharCode,
    width: i32,
    height: i32,
    extensions: CFDictionaryRef,
    formatDescriptionOut: *CMVideoFormatDescriptionRef,
) OSStatus;

/// Creates format description from QuickTime ImageDescription data (from stsd atom)
/// Preferred method for ProRes/QuickTime formats - handles codec-specific data
/// Returns: noErr (0) on success, negative error code on failure
/// Note: Must CFRelease() when done
pub extern "c" fn CMVideoFormatDescriptionCreateFromBigEndianImageDescriptionData(
    allocator: CFAllocatorRef,
    imageDescriptionData: [*]const u8,
    size: usize,
    stringEncoding: CFStringEncoding,
    flavor: CMImageDescriptionFlavor,
    formatDescriptionOut: *CMVideoFormatDescriptionRef,
) OSStatus;

/// Returns the system's default string encoding
pub extern "c" fn CFStringGetSystemEncoding() CFStringEncoding;

/// Gets the video dimensions from a format description
/// Returns: struct with width and height fields
pub extern "c" fn CMVideoFormatDescriptionGetDimensions(
    videoDesc: CMVideoFormatDescriptionRef,
) extern struct { width: i32, height: i32 };

/// Gets the media type from a format description (e.g., 'vide' for video)
pub extern "c" fn CMFormatDescriptionGetMediaType(
    desc: CMVideoFormatDescriptionRef,
) FourCharCode;

/// Gets the codec type from a format description (e.g., 'ap4h' for ProRes 4444)
pub extern "c" fn CMFormatDescriptionGetMediaSubType(
    desc: CMVideoFormatDescriptionRef,
) FourCharCode;

// ============================================================================
// CoreMedia - CMBlockBuffer functions
// ============================================================================

/// Creates a block buffer wrapping existing memory (compressed frame data)
/// Use kCFAllocatorNull as blockAllocator when wrapping Zig-allocated memory
/// Returns: noErr (0) on success, negative error code on failure
/// Note: Must CFRelease() when done
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

/// Returns the total length of data in the block buffer
pub extern "c" fn CMBlockBufferGetDataLength(
    theBuffer: CMBlockBufferRef,
) usize;

/// Gets a pointer to the data in the block buffer
/// Returns: noErr (0) on success, negative error code on failure
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

/// Creates a sample buffer (compressed frame + timing info)
/// Returns: noErr (0) on success, negative error code on failure
/// Note: Must CFRelease() when done
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

/// Creates a sample buffer that's immediately ready for use
/// Simpler version of CMSampleBufferCreate() - use this for single frames
/// Returns: noErr (0) on success, negative error code on failure
/// Note: Must CFRelease() when done
pub extern "c" fn CMSampleBufferCreateReady(
    allocator: CFAllocatorRef,
    dataBuffer: CMBlockBufferRef,
    formatDescription: CMVideoFormatDescriptionRef,
    numSamples: i32,
    numSampleTimingEntries: i32,
    sampleTimingArray: ?[*]const CMSampleTimingInfo,
    numSampleSizeEntries: i32,
    sampleSizeArray: ?[*]const u32,
    sampleBufferOut: *CMSampleBufferRef,
) OSStatus;

/// Extracts the image buffer (CVPixelBuffer) from a decoded sample buffer
/// Returns: CVPixelBufferRef or null if no image buffer attached
pub extern "c" fn CMSampleBufferGetImageBuffer(
    sbuf: CMSampleBufferRef,
) CVPixelBufferRef;

/// Gets the format description from a sample buffer
pub extern "c" fn CMSampleBufferGetFormatDescription(
    sbuf: CMSampleBufferRef,
) CMVideoFormatDescriptionRef;

/// Gets the presentation timestamp (PTS) from a sample buffer
pub extern "c" fn CMSampleBufferGetPresentationTimeStamp(
    sbuf: CMSampleBufferRef,
) CMTime;

/// Gets the duration from a sample buffer
pub extern "c" fn CMSampleBufferGetDuration(
    sbuf: CMSampleBufferRef,
) CMTime;

/// Checks if a sample buffer is valid and ready to use
/// Returns: non-zero if valid, 0 if invalid
pub extern "c" fn CMSampleBufferIsValid(
    sbuf: CMSampleBufferRef,
) Boolean;

// ============================================================================
// CoreMedia - CMTime functions
// ============================================================================

/// Creates a CMTime from value and timescale
/// Example: CMTimeMake(1, 24) = 1/24 second (one frame at 24fps)
pub extern "c" fn CMTimeMake(
    value: i64,
    timescale: i32,
) CMTime;

/// Converts CMTime to seconds (floating point)
pub extern "c" fn CMTimeGetSeconds(
    time: CMTime,
) f64;

/// Compares two CMTimes
/// Returns: -1 if time1 < time2, 0 if equal, 1 if time1 > time2
pub extern "c" fn CMTimeCompare(
    time1: CMTime,
    time2: CMTime,
) i32;

/// Adds two CMTimes together
pub extern "c" fn CMTimeAdd(
    addend1: CMTime,
    addend2: CMTime,
) CMTime;

/// Subtracts one CMTime from another
pub extern "c" fn CMTimeSubtract(
    minuend: CMTime,
    subtrahend: CMTime,
) CMTime;

/// Invalid/uninitialized time constant
pub const kCMTimeInvalid = CMTime{
    .value = 0,
    .timescale = 0,
    .flags = 0,
    .epoch = 0,
};

/// Zero time constant (time = 0 seconds)
pub const kCMTimeZero = CMTime{
    .value = 0,
    .timescale = 1,
    .flags = @intFromEnum(CMTimeFlags.kCMTimeFlags_Valid),
    .epoch = 0,
};

// ============================================================================
// CoreVideo - CVPixelBuffer functions
// ============================================================================

/// Gets the width of a pixel buffer in pixels
pub extern "c" fn CVPixelBufferGetWidth(
    pixelBuffer: CVPixelBufferRef,
) usize;

/// Gets the height of a pixel buffer in pixels
pub extern "c" fn CVPixelBufferGetHeight(
    pixelBuffer: CVPixelBufferRef,
) usize;

/// Gets the pixel format type (e.g., kCVPixelFormatType_32BGRA)
pub extern "c" fn CVPixelBufferGetPixelFormatType(
    pixelBuffer: CVPixelBufferRef,
) u32;

/// Locks the base address for CPU access
/// Must be called before accessing pixel data, matched with Unlock
/// Returns: 0 on success, error code on failure
pub extern "c" fn CVPixelBufferLockBaseAddress(
    pixelBuffer: CVPixelBufferRef,
    lockFlags: u64,
) i32;

/// Unlocks the base address after CPU access
/// Must be called after Lock to allow GPU access again
/// Returns: 0 on success, error code on failure
pub extern "c" fn CVPixelBufferUnlockBaseAddress(
    pixelBuffer: CVPixelBufferRef,
    unlockFlags: u64,
) i32;

/// Gets a pointer to the pixel data
/// Only valid while pixel buffer is locked
pub extern "c" fn CVPixelBufferGetBaseAddress(
    pixelBuffer: CVPixelBufferRef,
) ?*anyopaque;

/// Gets the number of bytes per row (may be larger than width * bytes_per_pixel)
pub extern "c" fn CVPixelBufferGetBytesPerRow(
    pixelBuffer: CVPixelBufferRef,
) usize;

/// Gets the number of separate planes in a planar pixel buffer
/// For tri-planar YCbCr formats, returns 3 (or 4 with alpha)
/// Returns: Number of planes (0 if not planar or error)
pub extern "c" fn CVPixelBufferGetPlaneCount(
    pixelBuffer: CVPixelBufferRef,
) usize;

/// Gets the base address of a specific plane in a planar pixel buffer
/// Must call CVPixelBufferLockBaseAddress first
/// planeIndex: 0 for Y, 1 for Cb, 2 for Cr in YCbCr formats
/// Returns: Pointer to plane data, or null on error
pub extern "c" fn CVPixelBufferGetBaseAddressOfPlane(
    pixelBuffer: CVPixelBufferRef,
    planeIndex: usize,
) ?*anyopaque;

/// Gets the width of a specific plane
/// For 4:4:4 formats, all planes have same width as buffer
/// For 4:2:2, Cb/Cr planes are half width
/// Returns: Width in pixels
pub extern "c" fn CVPixelBufferGetWidthOfPlane(
    pixelBuffer: CVPixelBufferRef,
    planeIndex: usize,
) usize;

/// Gets the height of a specific plane
/// For 4:4:4 and 4:2:2, all planes have same height
/// For 4:2:0, Cb/Cr planes are half height
/// Returns: Height in pixels
pub extern "c" fn CVPixelBufferGetHeightOfPlane(
    pixelBuffer: CVPixelBufferRef,
    planeIndex: usize,
) usize;

/// Gets the bytes per row for a specific plane
/// May include padding, so can be larger than width * bytes_per_pixel
/// Returns: Bytes per row
pub extern "c" fn CVPixelBufferGetBytesPerRowOfPlane(
    pixelBuffer: CVPixelBufferRef,
    planeIndex: usize,
) usize;

// ============================================================================
// CoreVideo - CVMetalTextureCache functions
// ============================================================================

/// Creates a Metal texture cache for converting CVPixelBuffers to Metal textures
/// Used for zero-copy rendering of decoded video frames
/// Returns: 0 on success, error code on failure
/// Note: Must CFRelease() when done
pub extern "c" fn CVMetalTextureCacheCreate(
    allocator: CFAllocatorRef,
    cacheAttributes: CFDictionaryRef,
    metalDevice: MTLDeviceRef,
    textureAttributes: CFDictionaryRef,
    cacheOut: *CVMetalTextureCacheRef,
) i32;

/// Creates a Metal texture from a CVPixelBuffer (zero-copy)
/// Texture shares memory with pixel buffer - no data copy
/// Returns: 0 on success, error code on failure
/// Note: Must CFRelease() the CVMetalTextureRef when done
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

/// Extracts the MTLTexture from a CVMetalTexture
/// Returns: Metal texture object (do not release - owned by CVMetalTexture)
pub extern "c" fn CVMetalTextureGetTexture(
    image: CVMetalTextureRef,
) MTLTextureRef;

/// Flushes the texture cache, releasing unused textures
/// Call periodically to prevent memory buildup
pub extern "c" fn CVMetalTextureCacheFlush(
    textureCache: CVMetalTextureCacheRef,
    options: u64,
) void;

// ============================================================================
// CVBuffer Attachments - Color space and format metadata
// ============================================================================

/// Gets an attachment from a CVBuffer (like CVPixelBuffer)
/// key: CFString for the attachment (e.g., kCVImageBufferYCbCrMatrixKey)
/// attachmentMode: Pass NULL to ignore
/// Returns: CFTypeRef containing the value, or NULL if not found
pub extern "c" fn CVBufferGetAttachment(
    buffer: CVBufferRef,
    key: CFStringRef,
    attachmentMode: ?*anyopaque,
) CFTypeRef;

/// Creates an immutable CFString from a C string
/// cStr: Null-terminated C string
/// encoding: Use kCFStringEncodingUTF8 (0x08000100)
pub extern "c" fn CFStringCreateWithCString(
    alloc: CFAllocatorRef,
    cStr: [*:0]const u8,
    encoding: u32,
) CFStringRef;

/// Gets the C string pointer from a CFString
/// Returns: Pointer to null-terminated C string, valid while CFString exists
pub extern "c" fn CFStringGetCStringPtr(
    theString: CFStringRef,
    encoding: u32,
) ?[*:0]const u8;

// CFString encoding constant
pub const kCFStringEncodingUTF8: u32 = 0x08000100;

// CVImageBuffer attachment keys (as C strings - we'll create CFStrings from these)
pub const kCVImageBufferYCbCrMatrixKey: [*:0]const u8 = "CVImageBufferYCbCrMatrix";
pub const kCVImageBufferColorPrimariesKey: [*:0]const u8 = "CVImageBufferColorPrimaries";
pub const kCVImageBufferTransferFunctionKey: [*:0]const u8 = "CVImageBufferTransferFunction";
pub const kCVImageBufferChromaLocationTopFieldKey: [*:0]const u8 = "CVImageBufferChromaLocationTopField";
pub const kCVImageBufferChromaLocationBottomFieldKey: [*:0]const u8 = "CVImageBufferChromaLocationBottomField";
pub const kCMFormatDescriptionExtension_Depth: [*:0]const u8 = "Depth";
pub const kCMFormatDescriptionExtension_FullRangeVideo: [*:0]const u8 = "FullRangeVideo";

// ============================================================================
// CoreFoundation - CFType functions
// ============================================================================

/// Decrements the reference count of a CF object, freeing it when count reaches 0
/// Must be called for every Create/Copy function and every CFRetain()
pub extern "c" fn CFRelease(cf: ?*anyopaque) void;

/// Increments the reference count of a CF object to extend its lifetime
/// Returns: the same pointer (return value usually discarded with `_`)
pub extern "c" fn CFRetain(cf: ?*const anyopaque) ?*const anyopaque;

/// Prints a description of a CoreFoundation object to stderr (for debugging)
/// Useful for inspecting CFDictionaries, CFArrays, etc.
pub extern "c" fn CFShow(obj: ?*const anyopaque) void;

/// Returns the CFTypeID for a CF object (unique identifier for its class)
pub extern "c" fn CFGetTypeID(cf: CFTypeRef) CFTypeID;

// ============================================================================
// CoreFoundation - CFArray functions
// ============================================================================

/// Returns the number of elements in a CFArray
pub extern "c" fn CFArrayGetCount(theArray: CFArrayRef) CFIndex;

/// Returns the value at the given index in a CFArray
/// Returns: pointer to the value (not retained, don't CFRelease it)
pub extern "c" fn CFArrayGetValueAtIndex(theArray: CFArrayRef, idx: CFIndex) ?*const anyopaque;

// ============================================================================
// CoreFoundation - CFDictionary functions
// ============================================================================

/// Creates an immutable dictionary (key-value map)
/// Used for passing attributes to VideoToolbox/CoreVideo APIs
/// Returns: CFDictionaryRef (must CFRelease() when done)
/// Note: Pass null for keyCallBacks and valueCallBacks for default behavior
pub extern "c" fn CFDictionaryCreate(
    allocator: CFAllocatorRef,
    keys: ?*const ?*const anyopaque,
    values: ?*const ?*const anyopaque,
    numValues: CFIndex,
    keyCallBacks: ?*const anyopaque,
    valueCallBacks: ?*const anyopaque,
) CFDictionaryRef;

/// Gets a value from a dictionary by key
/// Returns: value pointer or null if key not found
pub extern "c" fn CFDictionaryGetValue(
    theDict: CFDictionaryRef,
    key: ?*const anyopaque,
) ?*const anyopaque;

// ============================================================================
// CoreFoundation - CFNumber functions
// ============================================================================

/// Creates a CFNumber from a numeric value
/// Used to pass numbers in CF dictionaries
/// Returns: CFNumberRef (must CFRelease() when done)
pub extern "c" fn CFNumberCreate(
    allocator: CFAllocatorRef,
    theType: CFIndex,
    valuePtr: ?*const anyopaque,
) CFNumberRef;

/// Gets the value from a CFNumber
/// Returns: true if successful, false if failed
pub extern "c" fn CFNumberGetValue(
    number: CFNumberRef,
    theType: CFIndex,
    valuePtr: ?*anyopaque,
) Boolean;

/// CFNumber type for signed 32-bit integers
pub const kCFNumberSInt32Type: CFIndex = 3;

/// CFNumber type for 64-bit floating point
pub const kCFNumberFloat64Type: CFIndex = 13;

/// Gets the boolean value from a CFBoolean
/// Returns: true or false
pub extern "c" fn CFBooleanGetValue(
    boolean: CFTypeRef,
) Boolean;

// ============================================================================
// OSStatus error codes
// ============================================================================

/// Success status code (all Apple APIs return 0 on success)
pub const noErr: OSStatus = 0;

/// The decompression session is invalid or has been invalidated
pub const kVTInvalidSessionErr: OSStatus = -12903;

/// The decoder encountered corrupted or invalid compressed data
pub const kVTVideoDecoderBadDataErr: OSStatus = -12909;

/// The decoder doesn't support the format/codec
pub const kVTVideoDecoderUnsupportedDataFormatErr: OSStatus = -12910;

/// The decoder malfunctioned (internal error)
pub const kVTVideoDecoderMalfunctionErr: OSStatus = -12911;

/// The encoder malfunctioned (internal error)
pub const kVTVideoEncoderMalfunctionErr: OSStatus = -12912;

/// The decoder is not available right now (resource contention)
pub const kVTVideoDecoderNotAvailableNowErr: OSStatus = -12913;

/// Image rotation is not supported for this format
pub const kVTImageRotationNotSupportedErr: OSStatus = -12914;

/// The encoder is not available right now (resource contention)
pub const kVTVideoEncoderNotAvailableNowErr: OSStatus = -12915;

/// Test function to verify extern declarations compile and link correctly
/// Run with: zig build-exe videotoolbox_c.zig -framework VideoToolbox -framework CoreMedia -framework CoreVideo
pub fn main() !void {
    std.debug.print("Testing VideoToolbox extern declarations...\n", .{});

    // Test that we can reference the function pointer
    std.debug.print("VTDecompressionSessionCreate address: {*}\n", .{&VTDecompressionSessionCreate});

    std.debug.print("Extern declarations compiled successfully!\n", .{});
}
