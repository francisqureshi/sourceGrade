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

## 🚧 Current Phase

### Phase 4.3: Create VTDecompressionSession (Next)

**Goal**: Create the decoder session that will decode frames

**What's needed**:
1. Create output pixel buffer attributes dictionary (BGRA8 + Metal compatible)
2. Define decompression callback function
3. Create VTDecompressionOutputCallbackRecord
4. Call `VTDecompressionSessionCreate()`
5. Verify session created successfully

**Functions to use**:
- `CFDictionaryCreate()` - for pixel buffer attributes
- `VTDecompressionSessionCreate()` - create session
- Callback with signature matching `VTDecompressionOutputCallback`

---

## 📋 Remaining Phases

### Phase 4.4: Create CMBlockBuffer & CMSampleBuffer
- Create CMBlockBuffer from raw frame data
- Create CMSampleBuffer with timing info
- Use data from `SourceMedia.readFrame()`

### Phase 4.5: Decode Single Frame
- Call `VTDecompressionSessionDecodeFrame()`
- Implement callback to receive CVPixelBuffer
- Call `VTDecompressionSessionWaitForAsynchronousFrames()`

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

**Last Updated**: 2026-01-06
**Current Status**: Phase 4.2 Complete ✅ → Starting Phase 4.3
