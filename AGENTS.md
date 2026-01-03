# Agent Instructions

This project uses **bd** (beads) for issue tracking. Run `bd onboard` to get started.

## Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --status in_progress  # Claim work
bd close <id>         # Complete work
bd sync               # Sync with git
```

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd sync
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds


# General App description:

sourceGrade is a Zig learning project that aims to become a simple colour grading app that follows similar infrastructure to FilmLight Baselight.

## Goals and tech stack:
---

# sourceGrade Tech Stack & Architecture

**Project:** Professional-grade color grading application (learning copy of Baselight with custom innovations)

## Core Technologies

### Language
- **Zig** - Primary language for application core, cross-platform orchestration, and type-safe GPU bindings

### Graphics APIs

**macOS:**
- **Metal** - Native graphics and compute API
  - Zero-copy CVPixelBuffer → Metal texture pipeline
  - Unified compute + display
  - Optimized for Apple Silicon

**Linux/NVIDIA:**
- **CUDA** - Compute backend for color grading operations
  - Direct hardware access to RTX 4090
  - Superior performance for color transforms vs Vulkan Compute
  - Existing ecosystem (NPP, cuFFT for image processing)
- **Vulkan** - Display/presentation layer - to be confirmed
  - Frame presentation and window surface management

**Future (Optional):**
- **HIP** - AMD GPU support (CUDA-compatible syntax, low porting effort)
- **Vulkan Compute** - Universal fallback for non-NVIDIA/AMD hardware

### Video Pipeline

**macOS:**
- **VideoToolbox** - Hardware-accelerated video decode
  - Zero-copy decode to CVPixelBuffer
  - Native integration with Metal via CVMetalTextureCache
  - H.264, H.265/HEVC, ProRes, ProRes RAW support
  - Minimal CPU overhead

**Linux:**
- ** MAYBE FFmpeg (libavformat/libavcodec)** - Container demuxing -- to be decided.
  - MP4/MOV atom parsing and navigation
  - Format handling and timecode extraction
- **NVDEC** - NVIDIA hardware decode (via FFmpeg hwaccel)
- **VAAPI** - Intel/AMD hardware decode fallback

### Window Management

**macOS:**
- **Swift + AppKit** - Minimal window wrapper (~50 lines)
  - Creates NSWindow and CAMetalLayer
  - Passes layer pointer to Zig via FFI
  - Native menubar support
  - Pattern borrowed from Ghostty

**Linux:**
- **X11/XCB** or **Wayland** - Native window creation
  - Vulkan surface creation
  - Event handling passed to Zig core

### Database
- **PostgreSQL** - Local project/session management
  - Running on port 5433 (avoiding conflicts with Baselight/Homebrew)
  - Schema: sources, projects, timelines, clips, grade_nodes, versions tables
  - LISTEN/NOTIFY for real-time collaboration features (professional workflow pattern)
  - **pg.zig** bindings for type-safe database access

### UI Architecture

**Paradigm:** Custom immediate-mode GPU-rendered UI (game-like)
- Inspired by Casey Muratori's IMGUI and Ryan Fleury's UI series
- No standard widget toolkits (can't handle color wheels, curves, scopes, HDR)
- Single unified render surface for everything (video + UI + scopes)
- Feature flags instead of widget types (combinatorial flexibility)

**Pattern:**
```zig
// Immediate-mode widget construction
if (UI_Button("Save").clicked) {
    // handle click
}

// Feature flag composition for custom widgets
const color_wheel_flags = Clickable | Draggable | CustomRender | AnimateOnHover;
const wheel = makeWidget(color_wheel_flags, "Lift");
```

## Architecture Patterns

### Memory Tiered Model
```
GPU VRAM (2-8 frames)
    ↑
System RAM (dozens-hundreds of frames, decoded cache)
    ↑
NVMe Cache (rendered/graded cache, persistent)
    ↑
Storage/NAS 25Gbe/10Gbe (original media, never modified)
```

### Frame Pipeline
```
decode → upload → grade (GPU compute) → display
   ↓        ↓         ↓
 CPU     PCIe    VRAM resident
```

CPU decodes ahead while GPU grades current frame. Deep RAM buffer for decoded frames awaiting GPU upload.

### Rendering Strategy
**Cache computation, not drawing:**
- Expensive (3-5ms): Computing grades (CDL, curves, 3D LUT, spatial ops)
- Expensive (2ms): Frame analysis (waveforms, histograms)
- Cheap (0.1-0.5ms): Drawing textures and UI geometry

Redraw everything every frame (even at 6K), but only recompute grades when video/parameters change.

### UI Layout
```
┌─────────────────────────────────────────────────────────┐
│  Native Menubar                                         │
├──────────────┬──────────────────────────┬───────────────┤
│  Scopes      │   Video Viewer           │  Color Wheels │
│  (waveform,  │   (graded preview)       │  (grading     │
│   vector,    │                          │   controls)   │
│   histogram) │                          │               │
├──────────────┴──────────────────────────┴───────────────┤
│  Timeline (scrubber, thumbnails, clips)                 │
└─────────────────────────────────────────────────────────┘
```

All rendered in single Metal/Vulkan pass. Video viewer is just a textured quad.

## Development Workflow

### Platform Split
- **Primary development:** macOS (MacBook Pro M1 Pro) with Metal backend
- **CUDA development:** SSH to Fedora 42 workstation (Intel 14900k, RTX 4090)
  - Neovim via SSH + tmux
  - Frame dumps for quick visual checks (HTTP server preview)
  - VNC for real-time GUI testing
  - Physical monitor at workstation for color-critical dev work

### Build System
- **Zig build system** handles both platforms
  - Conditional compilation for Metal/CUDA backends
  - Links CUDA toolkit on Linux (nvcc for .cu files)
  - Links Metal framework on macOS

### Code Organization
```
sourceGrade/
├── build.zig
├── src/
│   ├── main.zig
│   ├── backends/
│   │   ├── metal/        # macOS rendering + compute
│   │   ├── cuda/         # Linux compute (.cu kernels + .zig wrapper)
│   │   └── vulkan/       # Linux display
│   ├── ui/               # Immediate-mode UI system
│   ├── video/            # Decode pipeline, frame management
│   └── grading/          # Color math, node graph
├── macos/
│   └── Sources/          # Swift window wrapper
└── shaders/
    ├── metal/            # .metal compute/fragment shaders
    └── cuda/             # .cu kernel files
```

## Design Principles

1. **Learn by doing what professionals do** - Not simplified frameworks
2. **Native backends over abstraction layers** - Performance matters for real-time grading
3. **Immediate-mode UI** - Simpler state management, better for tool UIs
4. **Cache computation, not drawing** - GPU is fast at compositing
5. **Explicit over implicit** - Zig philosophy applied throughout
6. **Understanding > convenience** - This is a learning project

## Key Influences & References

**UI Design:**
- Casey Muratori's IMGUI (2005) - Immediate-mode philosophy
- Ryan Fleury's UI series - Feature flags, autolayout, widget building
- Ghostty architecture - Swift/Zig bridge pattern for macOS

**GPU Architecture:**
- NVIDIA GPU Gems - Pipeline optimization, texture caching
- RasterGrid GPU cache article - Understanding memory hierarchy
- Game engine patterns - Frame-based allocators, render loops

**Professional Tools:**
- FilmLight Baselight - Database patterns, ICI custom UI framework
- DaVinci Resolve - Dual backend approach (CUDA + OpenCL/Metal)
- Nuke - Node graph architecture

**Video Processing:**
- FFmpeg documentation - Container formats, decode pipelines
- OpenColorIO - Color pipeline compilation to GPU shaders

## Current Status

**Implemented:**
- ✅ Metal bindings module
- ✅ Swift window wrapper (NSWindow + CAMetalLayer)
- ✅ Metal triangle rendering
- ✅ MP4/MOV atom parser (recursive, sample size tables, timecode)
- ✅ PostgreSQL schema (6 core tables)

**In Progress:**
- remove AVFoundation dependency by writing own version..
- VideoToolbox integration (CVPixelBuffer → Metal texture)
- Immediate-mode UI framework (button, slider, panel)

**Next Steps:**
- Frame extraction and decode pipeline
- Basic color grading operations (CDL)
- CUDA backend on Linux workstation
- Timeline with thumbnails
- Scopes (waveform, vectorscope, histogram)
