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

### Phase 4.6: Extract & Verify CVPixelBuffer ✅
**Completed**: 2026-01-09

**What we accomplished**:
- ✅ Enhanced callback to extract CVPixelBuffer information (width, height, pixel format, bytes per row)
- ✅ Implemented `FrameContext` struct to capture CVPixelBuffer from async callback
- ✅ Passed context through `decompressionOutputRefCon` parameter
- ✅ Added proper memory management with `CFRetain()` in callback and `CFRelease()` in main function
- ✅ Fixed pointer lifetime issues by passing `*FrameContext` instead of by-value

**Output**:
```
✅ Decoded CVPixelBuffer:
   Resolution: 4096x2928
   Pixel Format: 0x42475241 ('ARGB')
   Bytes per Row: 16384
   Total Size: 47972352 bytes
Got pixel buffer: *CVPixelBufferRef@6000016e00a0
```

**Key Learnings**:
- Context structs must live in caller's scope, not in function that passes them
- Pass context by pointer (`*FrameContext`) not by value to avoid lifetime issues
- `CFRetain()` increments ref count to keep CVPixelBuffer alive beyond callback
- `CFRetain()` returns a pointer value that must be discarded with `_` in Zig
- Storing pointer + retaining are both necessary (pointer = access, retain = lifetime)

**Files Modified**:
- `src/io/decode/vtb_decode.zig` - Added FrameContext struct, enhanced callback, added CFRetain/CFRelease

---

## ✅ COMPLETE PHASES

### Phase 6: VideoToolboxDecoder Struct ✅ COMPLETE (2026-01-09)

**Goal**: Create production-ready decoder struct that encapsulates session lifecycle

**What we accomplished**:
- ✅ Designed struct with fields: session, format_desc, frame_ctx, mctx, source_media
- ✅ Implemented `init()` - creates format description and decompression session
- ✅ Implemented `deinit()` - properly releases CF objects and invalidates session
- ✅ Added comprehensive doc comments to videotoolbox_c.zig (400+ lines documented)
- ✅ Implemented `decodeFrame()` - complete and functional!
  - ✅ Uses frame_index parameter correctly
  - ✅ Allocates buffer with mctx.allocator
  - ✅ Returns CVPixelBufferRef (unwrapped with error handling)
  - ✅ Proper defer cleanup for buffer, block_buffer, and sample_buffer
  - ✅ Resets frame_ctx.pixel_buffer to null before decode
  - ✅ Debug print for failed decode (null pixel_buffer)

**Design Decision**: Decoder tied 1:1 to SourceMedia clip (each clip gets its own decoder)

**Key Learnings**:
- Defers should be placed immediately after resource creation (not at end of function)
- Must unwrap optional pixel_buffer before returning (using if/else with error)
- Block buffer needs CFRelease (it's a CF object)
- Frame context must be reset to null before each decode

**Files Modified**:
- `src/io/decode/vtb_decode.zig` - Implemented VideoToolboxDecoder struct with init/deinit/decodeFrame
- `src/io/decode/videotoolbox_c.zig` - Added comprehensive documentation

---

### Phase 6.5: DecodedFrame Wrapper & Ownership Model ✅ COMPLETE (2026-01-09)

**Goal**: Clean up resource ownership - caller should own decoded frames, not decoder

**What we accomplished**:
- ✅ Fixed frame_ctx lifetime bug - changed from copy to heap-allocated pointer
  - `frame_ctx: FrameContext` → `frame_ctx: *FrameContext`
  - Allocate with `mctx.allocator.create(FrameContext)` in init()
  - Deallocate with `mctx.allocator.destroy(self.frame_ctx)` in deinit()
  - Fixes dangling pointer issue in callback
- ✅ Created `DecodedFrame` wrapper struct for safe ownership
  - Holds CVPixelBufferRef
  - Provides `deinit()` method that calls CFRelease()
- ✅ Updated `decodeFrame()` return type: `CVPixelBufferRef` → `DecodedFrame`
- ✅ Made `deinit()` accept `*const DecodedFrame` (non-mutating cleanup)
- ✅ Fixed double-release bug - removed defer on block_buffer (owned by sample_buffer)

**Key Learnings**:
- Callback context must live in struct field, not local variable - use heap allocation
- Sample buffer owns block buffer - don't release it separately
- deinit() methods should take `*const T` when they only deallocate
- Wrapper structs integrate cleanly with Zig's defer pattern

**API** (Production-Ready):
```zig
var decoder = try VideoToolboxDecoder.init(&source_media, &mctx);
defer decoder.deinit();

const frame = try decoder.decodeFrame(0);
defer frame.deinit();  // Caller owns the frame, manages cleanup

// Use frame.pixel_buffer as needed
std.debug.print("Frame: {*}\n", .{frame.pixel_buffer});
```

**Tested**:
- ✅ Single frame decode (ProRes 4444, 4608×3164, 8.7MB)
- ✅ Proper cleanup with no malloc errors
- ✅ Decoder lifetime independent from frame lifetime

**Files Modified**:
- `src/io/decode/vtb_decode.zig` - Heap-allocated frame_ctx, DecodedFrame wrapper
- `src/main.zig` - Updated to use `defer frame.deinit()` pattern

---

## 📋 Remaining Phases

### Phase 5: Synchronous Decode Wrapper ✅ SKIPPED
- ✅ Already have synchronous behavior with `VTDecompressionSessionWaitForAsynchronousFrames()`
- ✅ Frame context struct captures decoded frames
- Decision: Skip complex mutex/condition variable implementation (not needed)

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

**Last Updated**: 2026-01-09
**Current Status**: Phase 6.5 Complete ✅ → DecodedFrame API production-ready! Ready for Phase 7 (Integration with media.zig)

## 🎯 Recent Wins

- 🎉 **ProRes 4444 hardware decoding fully working!**
- ✅ Fixed frame_ctx lifetime issue - heap allocation for callback safety
- ✅ DecodedFrame wrapper for clean ownership semantics
- ✅ No more malloc errors - proper CF object lifecycle management
- Successfully capturing and retaining CVPixelBuffers from async decoder
- Proper memory management with CFRetain/CFRelease
- Full decode pipeline: MOV parsing → CMSampleBuffer → VTDecompressionSession → CVPixelBuffer → DecodedFrame
- Production-ready API with defer pattern integration
- Ready for Metal texture conversion and GPU rendering
