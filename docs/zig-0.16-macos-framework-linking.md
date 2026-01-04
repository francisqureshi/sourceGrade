# Zig 0.16 - macOS Framework Linking Guide

## Problem

When using `extern` declarations for macOS frameworks (VideoToolbox, CoreMedia, etc.), you get:

```
error: undefined symbol: _VTDecompressionSessionCreate
```

Even though the extern declarations are correct and frameworks are linked with `linkFramework()`.

## Root Cause

Zig's linker doesn't know where to find macOS frameworks by default. You must explicitly add framework search paths.

## Solution

Use `NativePaths.detect()` to find system framework directories, then add them to your module:

```zig
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "my_app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // ⭐ KEY FIX: Detect and add framework paths
    var io_instance: std.Io.Threaded = .init_single_threaded;
    defer io_instance.deinit();
    const io = io_instance.io();
    const native_paths = std.zig.system.NativePaths.detect(b.allocator, io, &target.result) catch |err| {
        std.debug.print("Warning: Failed to detect native paths: {}\n", .{err});
        @panic("Cannot detect framework paths");
    };

    // Add framework directories to module
    for (native_paths.framework_dirs.items) |dir| {
        exe.root_module.addFrameworkPath(.{ .cwd_relative = dir });
    }

    // Now link frameworks normally
    exe.root_module.linkSystemLibrary("c", .{});
    exe.root_module.linkFramework("VideoToolbox", .{});
    exe.root_module.linkFramework("CoreMedia", .{});
    exe.root_module.linkFramework("CoreVideo", .{});
    exe.root_module.linkFramework("CoreFoundation", .{});

    b.installArtifact(exe);
}
```

## Extern Declarations Pattern

Use manual `extern` declarations instead of `@cImport` for Apple frameworks (avoids header complexity):

```zig
// Opaque types
pub const VTDecompressionSessionRef = ?*opaque {};
pub const CMVideoFormatDescriptionRef = ?*opaque {};
pub const CFAllocatorRef = ?*opaque {};

// Basic types
pub const OSStatus = i32;
pub const FourCharCode = u32;

// Structs
pub const CMTime = extern struct {
    value: i64,
    timescale: i32,
    flags: u32,
    epoch: i64,
};

// Functions
pub extern "c" fn VTDecompressionSessionCreate(
    allocator: CFAllocatorRef,
    videoFormatDescription: CMVideoFormatDescriptionRef,
    videoDecoderSpecification: CFDictionaryRef,
    destinationImageBufferAttributes: CFDictionaryRef,
    outputCallback: ?*const anyopaque,
    decompressionSessionOut: *VTDecompressionSessionRef,
) OSStatus;

pub extern "c" fn CFRelease(cf: ?*anyopaque) void;
```

## Why This Works

`NativePaths.detect()` finds platform-specific paths:
- `/System/Library/Frameworks`
- `/Library/Frameworks`
- Xcode SDK paths

Once added with `addFrameworkPath()`, Zig's linker can resolve framework symbols.

## Reference

- GitHub issue: https://github.com/ziglang/zig/issues/25010
- Tested on: Zig 0.16.0-dev.1859+212968c57
- Platform: macOS 15.6.1 (Darwin 24.6.0)

## Alternative (Not Recommended)

Build object with Zig, link with clang:
```bash
zig build-obj src/main.zig -femit-bin=main.o
clang main.o -framework VideoToolbox -framework CoreMedia -o app
```

This works but defeats the purpose of using Zig's build system.
