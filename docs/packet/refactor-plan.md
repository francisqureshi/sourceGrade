# Main.zig Refactoring Plan: Separation of I/O and GPU Concerns

## Executive Summary

Refactor `src/main.zig` (704 lines) to separate I/O operations (file parsing, database) from GPU/rendering code. This improves testability, maintainability, and follows the single responsibility principle.

---

## Current State Analysis

### File Breakdown (704 lines)

| Lines | Function/Section | Category | Destination |
|-------|-----------------|----------|-------------|
| 1-16 | Imports, cImport | Setup | `main.zig` (reduced) |
| 18-24 | `frame_semaphore`, `displayLinkCallback` | GPU sync | `gpu/renderer.zig` |
| 27-49 | `RenderConfig`, `RenderContext` structs | GPU state | `gpu/renderer.zig` |
| 52-253 | `renderThread()` (~200 lines) | GPU render loop | `gpu/renderer.zig` |
| 255-318 | `testSourceMedia()` (~63 lines) | I/O test | Delete (duplicate of `media.zig:main`) |
| 319-365 | `testPgsql()` (~46 lines) | DB test | `tests/` or inline test |
| 367-616 | `main()` (~250 lines) | GPU setup + orchestration | Split between `gpu/` and `main.zig` |
| 618-703 | `testSourceIntegration()` (~85 lines) | I/O + DB test | `tests/` or inline test |

---

## Proposed File Structure

```
src/
├── main.zig                    # Thin orchestrator (~50 lines)
├── gpu/
│   ├── renderer.zig            # RenderContext, renderThread, GPU setup (~350 lines)
│   └── pipelines.zig           # Pipeline creation helpers (future)
├── io/
│   ├── db/
│   │   └── pgdb.zig            # Already exists - no changes
│   └── media.zig               # Already exists - no changes
├── imgui.zig                   # Already exists - no changes
└── tests/
    └── integration_test.zig    # testSourceIntegration, testPgsql (optional)
```

---

## Detailed Migration Plan

### Step 1: Create `src/gpu/renderer.zig` (NEW FILE)

**Move from main.zig:**
- Lines 18-24: `frame_semaphore`, `displayLinkCallback` 
- Lines 27-49: `RenderConfig`, `RenderContext` structs
- Lines 52-253: `renderThread()` function

**New additions:**
- `pub fn initRenderContext(...)` - Extract GPU setup from main()
- `pub fn deinitRenderContext(...)` - Cleanup

**File structure:**
```zig
// src/gpu/renderer.zig
const std = @import("std");
const metal = @import("metal");
const imgui = @import("../imgui.zig");

// C bridge for Swift window
const c = @cImport({
    @cInclude("metal_window.h");
});

// ============================================================================
// Synchronization
// ============================================================================

pub var frame_semaphore = std.Thread.Semaphore{};

pub export fn displayLinkCallback(_: ?*anyopaque) callconv(.c) void {
    frame_semaphore.post();
}

// ============================================================================
// Configuration & State
// ============================================================================

pub const RenderConfig = struct {
    use_display_p3: bool = true,
    use_10bit: bool = true,
};

pub const RenderContext = struct {
    window: *anyopaque,
    layer: *anyopaque,
    queue: metal.MetalCommandQueue,
    pipeline: metal.MetalRenderPipelineState,
    imgui_pipeline: metal.MetalRenderPipelineState,
    video_pipeline: metal.MetalRenderPipelineState,
    vertex_buffer: metal.MetalBuffer,
    index_buffer: metal.MetalBuffer,
    imgui_ctx: *imgui.ImGuiContext,
    displaylink: ?*anyopaque,
    start_time: std.time.Instant,
    video_reader: ?*anyopaque,
    device_ptr: *anyopaque,
    video_fps: f64,
    config: RenderConfig,
};

// ============================================================================
// Initialization
// ============================================================================

pub const InitError = error{
    MetalNotAvailable,
    WindowCreationFailed,
    LayerNotFound,
    DeviceNotFound,
    DisplayLinkCreationFailed,
    // ... Metal errors
};

pub const InitResult = struct {
    context: RenderContext,
    device: metal.MetalDevice,
    // ... other resources that need cleanup
};

/// Initialize all GPU resources. Returns context and resources.
/// Caller is responsible for cleanup via deinitRenderContext.
pub fn initRenderContext(
    allocator: std.mem.Allocator,
    config: RenderConfig,
    video_path: ?[:0]const u8,
) InitError!InitResult {
    // ... GPU setup code from main() lines 377-598
}

pub fn deinitRenderContext(result: *InitResult) void {
    // ... cleanup code
}

// ============================================================================
// Render Loop
// ============================================================================

/// Main render thread entry point. Runs until terminated.
pub fn renderThread(ctx: *RenderContext) void {
    // ... existing renderThread code (lines 52-253)
}
```

### Step 2: Delete `testSourceMedia()` (Lines 255-318)

**Rationale:** This function is a duplicate of `src/io/media.zig:main()` (lines 177-231). The media.zig version is the canonical implementation.

**Action:** Delete lines 255-318 from main.zig.

### Step 3: Move Test Functions to Inline Tests

**Option A (Recommended):** Convert to `test` blocks in pgdb.zig and media.zig

```zig
// src/io/db/pgdb.zig - add at bottom
test "database CRUD operations" {
    // Adapted from testPgsql()
}

// src/io/media.zig - add at bottom  
test "source media integration" {
    // Adapted from testSourceIntegration()
}
```

**Option B:** Keep as functions but move to separate test file

```zig
// src/tests/integration_test.zig
pub fn runDatabaseTests(pool: *pg.Pool) !void { ... }
pub fn runMediaIntegrationTests(allocator: Allocator) !void { ... }
```

### Step 4: Simplify `main.zig` to Orchestrator Only

**New main.zig (~50-80 lines):**

```zig
// src/main.zig
const std = @import("std");
const renderer = @import("gpu/renderer.zig");

pub fn main() !void {
    std.debug.print("=== sourceGrade ===\n\n", .{});
    
    // Setup allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Initialize GPU/rendering subsystem
    const config = renderer.RenderConfig{
        .use_display_p3 = true,
        .use_10bit = true,
    };
    
    var render_result = try renderer.initRenderContext(allocator, config, null);
    defer renderer.deinitRenderContext(&render_result);
    
    // Spawn render thread
    const thread = try std.Thread.spawn(.{}, renderer.renderThread, .{&render_result.context});
    thread.detach();
    
    // Run main event loop (never returns)
    renderer.runEventLoop();
    
    unreachable;
}
```

---

## Dependency Graph

```
main.zig
    ├── gpu/renderer.zig
    │       ├── metal (external)
    │       ├── imgui.zig
    │       │       ├── metal (external)
    │       │       └── text/font/*.zig
    │       └── macos/metal_window.h (C bridge)
    │
    └── io/
        ├── db/pgdb.zig
        │       └── pg (external)
        └── media.zig
                ├── mov.zig
                └── smpte (external)
```

**Key insight:** GPU code (`renderer.zig`, `imgui.zig`) and I/O code (`pgdb.zig`, `media.zig`) have **zero** cross-dependencies. Clean separation.

---

## Import Changes

### Before (main.zig)
```zig
const std = @import("std");
const builtin = @import("builtin");
const metal = @import("metal");
const pg = @import("pg");
const imgui = @import("imgui.zig");
const media = @import("io/media.zig");
const pgdb = @import("io/db/pgdb.zig");
const c = @cImport({ @cInclude("metal_window.h"); });
```

### After (main.zig)
```zig
const std = @import("std");
const renderer = @import("gpu/renderer.zig");
// pg, media, pgdb only imported if orchestrating I/O from main
```

### After (gpu/renderer.zig)
```zig
const std = @import("std");
const metal = @import("metal");
const imgui = @import("../imgui.zig");
const c = @cImport({ @cInclude("metal_window.h"); });
```

---

## Implementation Order

| Step | Description | Files Modified | Effort |
|------|-------------|----------------|--------|
| 1 | Create `src/gpu/` directory | - | 1 min |
| 2 | Create `renderer.zig` skeleton | `src/gpu/renderer.zig` (new) | 5 min |
| 3 | Move structs (`RenderConfig`, `RenderContext`) | `main.zig` -> `renderer.zig` | 10 min |
| 4 | Move `renderThread()` | `main.zig` -> `renderer.zig` | 15 min |
| 5 | Move `frame_semaphore`, `displayLinkCallback` | `main.zig` -> `renderer.zig` | 5 min |
| 6 | Extract `initRenderContext()` from `main()` | `main.zig` -> `renderer.zig` | 30 min |
| 7 | Delete `testSourceMedia()` | `main.zig` | 2 min |
| 8 | Move/convert test functions | `main.zig` -> tests or inline | 20 min |
| 9 | Simplify `main()` to orchestrator | `main.zig` | 15 min |
| 10 | Update `build.zig` if needed | `build.zig` | 5 min |
| 11 | Test and verify | - | 15 min |

**Total estimated effort: ~2 hours**

---

## Benefits

1. **Separation of Concerns**
   - GPU code isolated in `gpu/` - easier to add CUDA/Vulkan backends later
   - I/O code already isolated in `io/` - database and media parsing independent

2. **Testability**
   - GPU code can be unit tested without database
   - Database code can be tested without Metal
   - `main.zig` becomes trivial to review

3. **Maintainability**
   - `renderThread()` is 200 lines - belongs in its own module
   - Clear module boundaries make changes localized

4. **Scalability**
   - Adding a second render backend (CUDA) = new file in `gpu/`
   - Adding a second database (SQLite) = new file in `io/db/`
   - Main.zig stays thin regardless of app complexity

5. **Follows AGENTS.md Architecture**
   - Matches the `src/backends/` structure planned for CUDA/Vulkan
   - Aligns with "explicit over implicit" Zig philosophy

---

## Risk Assessment

| Risk | Mitigation |
|------|------------|
| C bridge (`metal_window.h`) path issues | Use `@import("../")` relative paths, verify in build |
| Thread safety with moved globals | `frame_semaphore` is already `var` at module level - works fine |
| Build.zig import changes | No changes needed - Zig handles module resolution |
| Breaking existing functionality | Incremental moves, test after each step |

---

## Success Criteria

- [ ] `zig build run` works after refactor
- [ ] `main.zig` is under 100 lines
- [ ] `gpu/renderer.zig` contains all GPU code
- [ ] No I/O imports in `gpu/` modules
- [ ] No GPU imports in `io/` modules
- [ ] All existing functionality preserved

---

## Future Considerations

After this refactor, the codebase is positioned for:

1. **CUDA Backend** (`src/gpu/cuda/`)
   - `renderer.zig` becomes Metal-specific
   - Add `cuda_renderer.zig` with same interface
   - `main.zig` selects backend at compile time

2. **Service Layer** (`src/services/`)
   - If app grows, add services that compose I/O + business logic
   - e.g., `GradingService` that uses `media.zig` + `pgdb.zig`

3. **CLI/GUI Split**
   - `main.zig` = GUI entry point
   - `cli.zig` = CLI entry point (no GPU)
   - Both use same I/O modules
