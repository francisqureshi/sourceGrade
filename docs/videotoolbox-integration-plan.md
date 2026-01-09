# VideoToolbox Integration Plan

**Goal**: Replace `@macos/VideoReader.swift` with Zig + VideoToolbox C API

---

## Current State ✅

- ✅ `mov.zig`: Parses MOV atoms, extracts frame offsets/sizes from mdat
- ✅ `media.zig`: High-level `SourceMedia` struct with metadata
- ✅ `readFrame()`: Returns raw compressed ProRes bytes
- ✅ **Phase 4.1-4.6**: Complete VideoToolbox decode pipeline working
- ✅ **Hardware ProRes 4444 decoding functional**

---

## Phase 4: Single Frame VideoToolbox Decode ✅ COMPLETED (2026-01-09)

**Goal**: Decode ONE ProRes frame to CVPixelBuffer

### Key Types
- **CMVideoFormatDescription** - Codec info from stsd atom
- **VTDecompressionSession** - Decoder instance (reusable)
- **CMBlockBuffer** - Wrapper around raw frame bytes
- **CMSampleBuffer** - Frame + timing container
- **CVPixelBuffer** - Decoded BGRA pixels (output)

### Completed Steps
1. ✅ Manual extern declarations (videotoolbox_c.zig) - `@cImport` not viable
2. ✅ Create CMVideoFormatDescription from `stsd_data`
3. ✅ Create VTDecompressionSession (output: BGRA8 + Metal compatible)
4. ✅ Create CMBlockBuffer from raw frame data
5. ✅ Create CMSampleBuffer (block buffer + timing)
6. ✅ Call `VTDecompressionSessionDecodeFrame()`
7. ✅ Callback fires with valid CVPixelBuffer
8. ✅ Extract CVPixelBuffer info (width, height, pixel format, bytes per row)
9. ✅ Capture CVPixelBuffer using FrameContext + CFRetain/CFRelease

**Status**: Fully functional ProRes 4444 hardware decode pipeline (4096x2928 tested)

---

## Phase 5: Synchronous Decode Wrapper ✅ OPTIONAL - ALREADY FUNCTIONAL

**Goal**: Block until decode completes, return CVPixelBuffer

### Current Implementation
- ✅ `VTDecompressionSessionWaitForAsynchronousFrames()` provides synchronous blocking
- ✅ `FrameContext` struct captures CVPixelBuffer from callback
- ✅ Proper reference counting with `CFRetain()` in callback, `CFRelease()` after use

**Note**: More complex synchronization (mutex + condition variable) not needed for current use case

---

## Phase 6: VideoToolboxDecoder Struct 🚧 NEXT

**Goal**: Encapsulate session lifecycle for production use

**Proposed API**:
```zig
pub const VideoToolboxDecoder = struct {
    session: VTDecompressionSessionRef,
    format_desc: CMVideoFormatDescriptionRef,
    frame_ctx: FrameContext,

    pub fn init(stsd_data: []const u8, width: u16, height: u16) !VideoToolboxDecoder
    pub fn deinit(self: *VideoToolboxDecoder) void
    pub fn decodeFrame(self: *VideoToolboxDecoder, frame_data: []const u8, pts: CMTime) !CVPixelBufferRef
};
```

**Benefits**:
- Reusable decoder instance (create once, decode many frames)
- Automatic cleanup via `deinit()`
- Thread-safe frame context management

---

## Phase 7: Integration with media.zig 🚧 FUTURE

**Changes**:
- Add `decoder: VideoToolboxDecoder` field to `SourceMedia`
- Initialize in `SourceMedia.init()` using `stsd_data`
- `readFrame()` returns `CVPixelBuffer` instead of raw bytes
- Port `CVMetalTextureCache` conversion from Swift
- Remove Swift VideoReader dependency entirely

---

## Validation

Each phase:
1. Compare with Swift implementation (same frame, verify pixels match)
2. Run under Instruments (check memory leaks)
3. Test frames: 0, 100, last (compare with FFmpeg extraction)

**Phase 4 Validation Results**:
- ✅ ProRes 4444 decode successful (4096x2928)
- ✅ Pixel format: BGRA (0x42475241)
- ✅ Hardware decode confirmed via `VTIsHardwareDecodeSupported()`
- ✅ CVPixelBuffer properly captured and released
- 🔲 Memory leak testing pending (run Instruments)

---

## Common Issues ✅ RESOLVED

| Problem | Cause | Fix | Status |
|---------|-------|-----|--------|
| Format desc fails | Wrong FourCC mapping | Use `CMVideoFormatDescriptionCreateFromBigEndianImageDescriptionData` | ✅ Fixed |
| Session fails | Invalid output format | Try without Metal compat first | ✅ Working |
| Error -12909 | Bad CMTime | Verify timescale from media_header | ✅ Working |
| No callback | Didn't wait async | Add `WaitForAsynchronousFrames()` | ✅ Implemented |
| Callback status != 0 | Corrupt frame data | Compare with ffprobe extraction | ✅ Working |
| `@cImport` fails | Apple headers too complex | Use manual extern declarations | ✅ Fixed |
| Context lifetime | Local var destroyed before callback | Pass pointer from caller's scope | ✅ Fixed |
| CVPixelBuffer freed early | Missing CFRetain | Retain in callback, release after use | ✅ Fixed |

---

## Implementation Files

**Created**:
- `src/io/decode/videotoolbox_c.zig` - Manual C API bindings (400+ lines)
- `src/io/decode/vtb_decode.zig` - Decode pipeline implementation
- `docs/zig-0.16-macos-framework-linking.md` - Framework linking guide
- `docs/progress_tracker.md` - Detailed phase tracking

**Modified**:
- `src/io/media.zig` - Added `stsd_data` field
- `build.zig` - Framework linking configuration

---

## Key Learnings

1. **Manual extern declarations** work better than `@cImport` for Apple frameworks
2. **Framework linking** requires `NativePaths.detect()` + `addFrameworkPath()` in Zig 0.16
3. **QuickTime stsd atom** structure: `[version/flags:4][entry_count:4][ImageDescription...]`
4. **CMTime mapping**: `value = frame_index × den`, `timescale = num` (from `Rational`)
5. **Context passing**: Must live in caller's scope, pass by pointer
6. **CoreFoundation reference counting**: Use CFRetain/CFRelease for objects allocated by Apple frameworks

---

## Next Action

**Phase 6**: Create `VideoToolboxDecoder` struct to encapsulate session lifecycle and enable reusable, production-ready decoding.

See `src/io/decode/vtb_decode.zig` for current working implementation. 
