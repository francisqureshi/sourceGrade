# VideoToolbox Integration Progress Tracker

**Goal**: Replace `@macos/VideoReader.swift` with pure Zig + VideoToolbox C API

---

## ✅ Completed Phases

### Phase 1-3: MOV Parsing & Media Infrastructure
- ✅ `mov.zig`: Parses QuickTime/MOV container format
- ✅ Extract frame offsets/sizes from mdat atom
- ✅ Parse stsd, stts, stsc, stsz, stco atoms
- ✅ `media.zig`: SourceMedia struct with metadata
- ✅ `readFrame()`: Returns raw compressed ProRes bytes

**Files**: `src/io/mov.zig`, `src/io/media.zig`

---

### Phase 4.1: C API Bindings ✅
**Completed**: 2026-01-06

Created complete manual extern declarations for Apple frameworks:
- ✅ `videotoolbox_c.zig`: 400+ lines of C API bindings
- ✅ All VTDecompressionSession functions
- ✅ All CoreMedia functions (CMTime, CMSampleBuffer, CMBlockBuffer, CMFormatDescription)
- ✅ All CoreVideo functions (CVPixelBuffer, CVMetalTextureCache)
- ✅ All CoreFoundation helpers (CFRelease, CFDictionary, CFNumber)
- ✅ Callback structures (VTDecompressionOutputCallbackRecord)
- ✅ Constants (codec types, pixel formats, error codes)
- ✅ Fixed framework linking using `NativePaths.detect()`

**Key Learning**:
- Manual extern declarations work better than `@cImport` for Apple frameworks
- Framework linking requires `NativePaths.detect()` + `addFrameworkPath()` in Zig 0.16
- Calling convention is `.c` (lowercase) not `.C` in Zig 0.16

**Files**: `src/io/decode/videotoolbox_c.zig`, `build.zig`

---

### Phase 4.2: Create CMVideoFormatDescription ✅
**Completed**: 2026-01-06

- ✅ Implemented `decode()` function in `vt_decode.zig`
- ✅ Convert `SourceMedia.codec` slice to `[4]u8` array
- ✅ Bitcast codec FourCC from `[4]u8` to `u32`
- ✅ Call `CMVideoFormatDescriptionCreate()` with proper parameters
- ✅ Error handling with VideoToolboxError enum
- ✅ Memory management with `defer vtb.CFRelease()`
- ✅ Verified with real ProRes 4444 file (4096x2928)
- ✅ Tested from `main.zig` with actual SourceMedia

**Output**:
```
=== VideoToolbox Tests ===
✅ Format description created: *io.decode.videotoolbox_c.CMVideoFormatDescriptionRef__opaque_28821@6000024c40f0
   Codec FourCC: 0x68347061 ('ap4h')
   Dimensions: 4096x2928
```

**Key Learning**:
- Slice `[0..4].*` converts `[]const u8` to `[4]u8` for bitcasting
- OSStatus 0 = success, negative = error
- CMVideoFormatDescription is an opaque CF object with retain count = 1
- Endianness: FourCC stored little-endian on Intel/ARM Macs

**Files**: `src/io/decode/vt_decode.zig`, `src/main.zig`

---

### Phase 4.3: Create VTDecompressionSession ✅
**Completed**: 2026-01-08

**What we accomplished**:
- ✅ Added `stsd_data` field to `SourceMedia` struct (with proper allocation/deallocation)
- ✅ Used `CMVideoFormatDescriptionCreateFromBigEndianImageDescriptionData` for QuickTime/ProRes
- ✅ Correctly extracted ImageDescription from stsd atom (offset 8 bytes)
- ✅ Added `CFStringEncoding`, `CMImageDescriptionFlavor`, and `CFStringGetSystemEncoding()` to C bindings
- ✅ Created CFNumber for pixel format (kCVPixelFormatType_32BGRA)
- ✅ Created CFDictionary for pixel buffer attributes (BGRA + Metal compatibility)
- ✅ Defined `decompressionOutputCallback` with correct signature (export fn, .c callconv)
- ✅ Created VTDecompressionOutputCallbackRecord
- ✅ Successfully called `VTDecompressionSessionCreate()`
- ✅ Fixed defer order for proper cleanup (Invalidate then Release in single defer block)

**Key Learnings**:
- `extern var` values are already pointers - don't use `&` when passing CFString extern vars
- Zig defer statements execute in REVERSE order (LIFO) - combine related cleanup in single defer block
- QuickTime stsd atom structure: [4 bytes version/flags][4 bytes entry count][ImageDescription...]
- `CMVideoFormatDescriptionCreateFromBigEndianImageDescriptionData` is the correct API for QuickTime/ProRes

**Output**:
```
Format description created: *CMVideoFormatDescriptionRef@...
   Codec FourCC: 0x61703468 ('h4pa')
   Dimensions: 4096x2928
✅ Decompression session created successfully!
🎉 Phase 4.3 Complete! VTDecompressionSession created successfully!
```

**Files Modified**:
- `src/io/media.zig` - Added `stsd_data` field
- `src/io/decode/videotoolbox_c.zig` - Added CMVideoFormatDescriptionCreateFromBigEndianImageDescriptionData
- `src/io/decode/vt_decode.zig` - Implemented complete session creation

---

### Phase 4.4: Create CMBlockBuffer & CMSampleBuffer ✅
**Completed**: 2026-01-08

**What we accomplished**:
- ✅ Read raw frame data using `SourceMedia.readFrame()` (8.7MB ProRes frame)
- ✅ Created CMBlockBuffer wrapping compressed frame bytes with `CMBlockBufferCreateWithMemoryBlock()`
- ✅ Created CMSampleTimingInfo with PTS = frame_index × frame_duration, duration = frame_duration
- ✅ Created CMSampleBuffer combining block buffer + timing + format description with `CMSampleBufferCreateReady()`
- ✅ Made `getFrameSize()` and `readFrame()` accept const pointers (they don't mutate)
- ✅ Added `CMSampleBufferCreateReady` binding to videotoolbox_c.zig

**Key Learnings**:
- `CMTime` maps directly to `Rational`: value = frame_index × den, timescale = num
- PTS for frame N: `CMTimeMake(N × frame_rate.den, frame_rate.num)`
- `@intCast(usize → i32)` needed for timescale conversion
- Array literals `&[_]Type{val}` convert single pointers to many-pointers for C APIs
- Zig defer moves cleanup of dependent objects to single block (timing_info depends on frame_rate)

**Output**:
```
block_buffer: *CMBlockBufferRef@...
sample_buffer: *CMSampleBufferRef@...
```

**Technical Note**: Currently mixing Zig allocator with CoreFoundation (kCFAllocatorNull). Buffer lifetime works for single frame, but should refactor before production use.

**Files Modified**:
- `src/io/decode/vtb_decode.zig` - Added createSampleTimingInfo() and createSampleBuffer() functions
- `src/io/decode/videotoolbox_c.zig` - Added CMSampleBufferCreateReady binding
- `src/io/media.zig` - Made getFrameSize() and readFrame() accept const pointers

---

### Phase 4.5: Decode Single Frame ✅
**Completed**: 2026-01-08

**What we accomplished**:
- ✅ Implemented `decompress()` function calling `VTDecompressionSessionDecodeFrame()`
- ✅ Added `VTDecompressionSessionWaitForAsynchronousFrames()` to block until decoder finishes
- ✅ Successfully decoded first ProRes frame (8.7MB compressed → CVPixelBuffer)
- ✅ Callback invoked with decoded CVPixelBuffer

**Output**:
```
✅ Decode callback received frame: *CVPixelBufferRef@...
✅ Frame sent to decoder
✅ Decoder finished, callback was invoked
```

**Key Learning**:
- `VTDecompressionSessionDecodeFrame()` is async—it returns immediately
- `VTDecompressionSessionWaitForAsynchronousFrames()` blocks until callback completes
- Callback fires on background thread with CVPixelBuffer result

**Files Modified**:
- `src/io/decode/vtb_decode.zig` - Implemented decompress() function, added error types

---

## 🚧 Current Phase

### Phase 4.6: Extract & Verify CVPixelBuffer (Next)

---

## 📋 Remaining Phases

### Phase 4.5: Decode Single Frame (Not Started)
- Call `VTDecompressionSessionDecodeFrame()` with CMSampleBuffer
- Wait for callback to receive CVPixelBuffer
- Call `VTDecompressionSessionWaitForAsynchronousFrames()` to ensure completion

### Phase 5: Synchronous Decode Wrapper
- Add mutex + condition variable for blocking
- Frame context struct
- Make decode synchronous (return CVPixelBuffer directly)

### Phase 6: VideoToolboxDecoder Struct
- Encapsulate session lifecycle
- `init()` / `deinit()` methods
- Reusable decoder instance

### Phase 7: Integration with media.zig
- Add decoder to SourceMedia
- Change readFrame() to return CVPixelBuffer
- Port CVMetalTextureCache from Swift
- Remove Swift VideoReader dependency

---

## 📚 Documentation Created

- ✅ `docs/zig-0.16-macos-framework-linking.md` - Framework linking guide
- ✅ `docs/videotoolbox-integration-plan.md` - Original implementation plan
- ✅ `docs/progress_tracker.md` - This file

---

## 🎯 Success Metrics

- [ ] Decode ProRes frames without Swift
- [ ] Performance matches or exceeds Swift implementation
- [ ] No memory leaks (verified with Instruments)
- [ ] Clean error handling
- [ ] All ProRes variants supported (422, 422HQ, 4444, etc.)

---

**Last Updated**: 2026-01-08
**Current Status**: Phase 4.4 Complete ✅ → Starting Phase 4.5

## 🎯 Recent Wins

- Successfully created CMSampleBuffer with timing info from frame data!
- Block buffer + timing + format description all working together
- Ready to feed sample buffer to decoder and receive CVPixelBuffer
- ProRes 4444 decoding pipeline 80% complete
