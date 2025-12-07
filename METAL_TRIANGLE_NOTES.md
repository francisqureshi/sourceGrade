# Metal Triangle Rendering in Zig

## Current Status

This project demonstrates **Metal compute shaders** using the `metal_bindings` library.

The compute shader demo (`zig build run`) successfully:
- Creates a Metal device (Apple GPU)
- Compiles and runs a compute shader
- Processes data on the GPU
- Reads results back to CPU

## What's Needed for Full Triangle Rendering

The Apple tutorial "Drawing a triangle with Metal 4" uses **render pipelines**, which require:

### 1. Window and View Management (AppKit/MetalKit)
```objective-c
NSWindow, NSView, MTKView
CAMetalLayer (for drawable surfaces)
```

### 2. Render Pipeline (vs Compute Pipeline)
```objective-c
MTLRenderPipelineState
MTLRenderPassDescriptor
MTLRenderCommandEncoder (vs MTLComputeCommandEncoder)
```

### 3. Graphics-Specific Concepts
- **Viewports** - Define the rendering area
- **Vertex/Fragment shaders** - Process geometry and pixels
- **Drawables** - Frame buffers to render into
- **Present** - Display rendered frames on screen

### 4. Metal 4 Specific APIs
The tutorial uses Metal 4 APIs introduced in macOS 12.0+:
- `MTL4CommandQueue`
- `MTL4CommandBuffer`
- `MTL4ArgumentTable`
- `MTL4RenderCommandEncoder`
- `MTLResidencySet`
- `MTL4Compiler`

## Current Library Limitations

The `metal_bindings` library (francisqureshi/metal-bindings) focuses on:
- **Compute shaders** (GPGPU work)
- **Command buffers and queues**
- **Buffer and texture management**

It does NOT include:
- AppKit/UIKit window/view bindings
- Render pipeline creation
- Drawable/presentation layer management

## Alternatives for Triangle Rendering

### Option 1: Use `zig-metal` Library
The `dmbfm/zig-metal` library provides AppKit and MetalKit extras:
```zig
@import("zig-metal").extras.appkit
@import("zig-metal").extras.metalkit
```

### Option 2: Create Objective-C Bindings
Manually bind the required Cocoa/Metal APIs:
- NSWindow, NSApplication
- MTKView, MTKViewDelegate
- MTLRenderPipelineDescriptor
- CAMetalDrawable

### Option 3: SDL/GLFW with Metal Backend
Use a cross-platform windowing library that supports Metal rendering.

## Files in This Project

- `src/main.zig` - Metal compute shader demo (working)
- `src/Shaders.metal` - Vertex/fragment shaders (for reference)
- This reference implementation shows the structure needed for triangle rendering

## Key Concepts from Apple Tutorial

### Frame Management
The tutorial renders at 60 FPS with 3 frames in-flight:
1. Frame N: Being displayed
2. Frame N+1: Being rendered by GPU
3. Frame N+2: Being encoded by CPU

### Resource Synchronization
- Uses `MTLSharedEvent` to track frame completion
- Rotates through 3 command allocators
- Employs residency sets for memory management

### Pipeline Configuration
```objective-c
MTL4RenderPipelineDescriptor *desc = [MTL4RenderPipelineDescriptor new];
desc.vertexFunctionDescriptor = vertexShader;
desc.fragmentFunctionDescriptor = fragmentShader;
desc.colorAttachments[0].pixelFormat = pixelFormat;
```

## Next Steps

To implement full triangle rendering in Zig:

1. Choose a windowing approach (AppKit bindings, SDL, or zig-metal)
2. Create render pipeline bindings
3. Implement frame synchronization
4. Set up drawable presentation layer
5. Port the vertex/fragment shaders (already in `Shaders.metal`)

## References

- [Apple Metal 4 Triangle Tutorial](https://developer.apple.com/documentation/metal/drawing-a-triangle-with-metal-4)
- [Current metal_bindings library](https://github.com/francisqureshi/metal-bindings)
- [Alternative zig-metal library](https://github.com/dmbfm/zig-metal)
- [Zig's New Async I/O](https://andrewkelley.me/post/zig-new-async-io-text-version.html) (for async rendering loop)
