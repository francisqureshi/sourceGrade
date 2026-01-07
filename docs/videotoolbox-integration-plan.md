# VideoToolbox Integration Plan

**Goal**: Replace `@macos/VideoReader.swift` with Zig + VideoToolbox C API

---

## Current State ✅

- ✅ `mov.zig`: Parses MOV atoms, extracts frame offsets/sizes from mdat
- ✅ `media.zig`: High-level `SourceMedia` struct with metadata
- ✅ `readFrame()`: Returns raw compressed ProRes bytes

---

## Phase 4: Single Frame VideoToolbox Decode

**Goal**: Decode ONE ProRes frame to CVPixelBuffer

### Key Types
- **CMVideoFormatDescription** - Codec info from stsd atom
- **VTDecompressionSession** - Decoder instance (reusable)
- **CMBlockBuffer** - Wrapper around raw frame bytes
- **CMSampleBuffer** - Frame + timing container
- **CVPixelBuffer** - Decoded BGRA pixels (output)

### Steps
1. `@cImport` VideoToolbox/CoreMedia/CoreVideo headers
2. Create CMVideoFormatDescription from `stsd_data`
3. Create VTDecompressionSession (output: BGRA8 + Metal compatible)
4. Create CMBlockBuffer from raw frame data
5. Create CMSampleBuffer (block buffer + timing)
6. Call `VTDecompressionSessionDecodeFrame()`
7. Verify callback fires with valid CVPixelBuffer

---

## Phase 5: Synchronous Decode Wrapper

**Goal**: Block until decode completes, return CVPixelBuffer

### Approach
- Frame context with mutex + condition variable
- Callback signals when complete
- `decodeFrameSync()` waits and returns pixel buffer
- Caller must `CVPixelBufferRelease()` when done

---

## Phase 6: VideoToolboxDecoder Struct

**Goal**: Encapsulate session lifecycle

```zig
pub const VideoToolboxDecoder = struct {
    session: VTDecompressionSessionRef,
    format_desc: CMVideoFormatDescriptionRef,

    pub fn init(stsd_data: []const u8, width: u16, height: u16) !VideoToolboxDecoder
    pub fn deinit(self: *VideoToolboxDecoder) void
    pub fn decodeFrame(self: *VideoToolboxDecoder, frame_data: []const u8, pts: CMTime) !*CVPixelBuffer
};
```

---

## Phase 7: Integration with media.zig

**Changes**:
- Add `decoder: VideoToolboxDecoder` field to `SourceMedia`
- Initialize in `SourceMedia.init()` using `stsd_data`
- `readFrame()` returns `CVPixelBuffer` instead of raw bytes
- Port `CVMetalTextureCache` conversion from Swift

---

## Validation

Each phase:
1. Compare with Swift implementation (same frame, verify pixels match)
2. Run under Instruments (check memory leaks)
3. Test frames: 0, 100, last (compare with FFmpeg extraction)

---

## Common Issues

| Problem | Cause | Fix |
|---------|-------|-----|
| Format desc fails | Wrong FourCC mapping | Check codec: apcn=422, apch=422HQ, ap4h=4444 |
| Session fails | Invalid output format | Try without Metal compat first |
| Error -12909 | Bad CMTime | Verify timescale from media_header |
| No callback | Didn't wait async | Add `WaitForAsynchronousFrames()` |
| Callback status != 0 | Corrupt frame data | Compare with ffprobe extraction |

---

## Resources

**Headers**:
- `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/VideoToolbox.framework/Headers/VTDecompressionSession.h`

**Key Functions**:
- `CMVideoFormatDescriptionCreate()`
- `VTDecompressionSessionCreate()`
- `CMBlockBufferCreateWithMemoryBlock()`
- `CMSampleBufferCreate()`
- `VTDecompressionSessionDecodeFrame()`
- `VTDecompressionSessionWaitForAsynchronousFrames()`

---

## Next Action

**Start**: Phase 4, Step 1 - Test `@cImport` in new file `src/io/video_decoder.zig`

```zig
const c = @cImport({
    @cInclude("VideoToolbox/VideoToolbox.h");
});

pub fn main() !void {
    std.debug.print("VT Type ID: {}\n", .{c.VTGetTypeID()});
}
```




next bit 4.3


  The trailing comma tells zig fmt to keep it multi-line. Otherwise it tries to
  compress it to one line if it fits within 100 characters.

  Alternative: If you want more control, break it into intermediate variables:

  const codec_fourcc: vtb.FourCharCode = @bitCast(source_media.codec[0..4].*);
  const width: i32 = @intCast(source_media.resolution.width);
  const height: i32 = @intCast(source_media.resolution.height);

  const status = vtb.CMVideoFormatDescriptionCreate(
      null,
      codec_fourcc,
      width,
      height,
      null,
      &format_desc,
  );

  This is also more readable! Which style do you prefer?

> great so next steps:

⏺ Perfect! Now let's tackle Phase 4.3: Create VTDecompressionSession!

  Here's what you need to implement in a new createDecompressionSession() function:

  Step-by-step:

  1. Create pixel buffer attributes dictionary (tells VT you want BGRA8 + Metal
  compatible output)
    - Use CFDictionaryCreate()
    - Keys: pixel format type, Metal compatibility
    - Values: kCVPixelFormatType_32BGRA, true
  2. Define the callback function (receives decoded frames)
    - Must match VTDecompressionOutputCallback signature
    - Use export fn with .c calling convention
    - For now, just print that it was called
  3. Create callback record
    - VTDecompressionOutputCallbackRecord struct
    - Contains: callback function pointer + context pointer
  4. Call VTDecompressionSessionCreate()
    - Pass format description, callback record, pixel buffer attributes
    - Returns the session
  5. Add error handling for session creation failure

  Key challenge: Creating the CFDictionary for pixel buffer attributes is the
  trickiest part. You need to create CF objects for the keys and values.

  Want to try implementing this yourself, or should I guide you through the
  CFDictionary creation first (since that's the most complex part)? 
