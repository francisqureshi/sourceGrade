# Zig Modern I/O Guide (0.15.1+)

> **Critical Context**: Zig 0.15.1 introduced massive breaking changes to I/O. This guide covers the new `std.Io` interface and `std.Io.Reader`/`std.Io.Writer` APIs that replaced the old generic readers/writers.

## Table of Contents

1. [Philosophy: Why This Changed](#philosophy-why-this-changed)
2. [The New std.Io Interface](#the-new-stdio-interface)
3. [Reader and Writer APIs](#reader-and-writer-apis)
4. [File Operations](#file-operations)
5. [Concurrency Patterns](#concurrency-patterns)
6. [Practical Examples](#practical-examples)
7. [Migration from Old API](#migration-from-old-api)

---

## Philosophy: Why This Changed

Andrew Kelley's talk "Don't Forget To Flush" (Systems Distributed 2025) explains the core insight:

**Key Insight**: Just like you pass an `Allocator` to code that needs memory, you now pass an `Io` to code that does I/O. This makes concurrency model explicit and composable.

### The Core Problems Solved:

1. **Old API was generic** - Poisoned structs with `anytype`, forced everything to be generic
2. **Buffer was below the vtable** - Performance penalty, especially in debug mode
3. **No concurrency model abstraction** - Code was locked to specific threading/async model
4. **Error sets were opaque** - Errors passed through as `anyerror`, not actionable

### The New Design:

- **Buffer is in the interface** (above the vtable) - Compiler can inline/optimize
- **Concrete, non-generic types** - `std.Io.Reader` and `std.Io.Writer` are structs, not generics
- **Precise error sets** - Each function has well-defined errors
- **Concurrency agnostic** - Same code works with threads, async, or blocking

---

## The New std.Io Interface

### Core Structure

```zig
const std = @import("std");

pub fn main(io: std.Io) !void {
    // Your code receives an Io instance
    // This determines the concurrency model
}
```

### The std.Io Type

```zig
// Fields
userdata: ?*anyopaque  // Implementation-specific data
vtable: *const VTable  // Function pointers for operations
```

### Available Implementations

#### 1. **std.Io.Threaded** - Thread Pool

```zig
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer _ = gpa.deinit();
const allocator = gpa.allocator();

var io_impl: std.Io.Threaded = .init(allocator);
defer io_impl.deinit();

// Configure thread count (defaults to CPU count)
io_impl.cpu_count = 4;

const io = io_impl.io();

// Now pass 'io' to your functions
try myWork(io);
```

#### 2. **std.Io.Evented** - Event-Driven I/O

```zig
// Uses io_uring (Linux) or kqueue (macOS)
var event_io: std.Io.Evented = undefined;
try event_io.init(allocator, .{});
defer event_io.deinit();

const io = event_io.io();
```

**Note**: As of late 2024, kqueue support is still in development. io_uring works on Linux.

#### 3. Single-threaded Blocking (Built-in)

For simple programs, you can use the default blocking implementation (details TBD in final 0.16.0 release).

---

## Reader and Writer APIs

### Critical Concept: You Provide the Buffer

**Old way:**
```zig
// Buffer hidden inside implementation
var buffered_reader = std.io.bufferedReader(file.reader());
```

**New way:**
```zig
// You provide the buffer explicitly
var buffer: [4096]u8 = undefined;
var reader = file.reader(&buffer);
```

### std.Io.Reader

#### Structure

```zig
pub const Reader = struct {
    vtable: *const VTable,
    buffer: []u8,           // Your buffer
    seek: usize,            // Bytes consumed from buffer
    end: usize,             // Buffered bytes (undefined after this)
    
    // ... methods ...
};
```

#### Essential Reading Methods

```zig
// Peek without advancing position
const byte = try reader.peekByte();
const data = try reader.peek(10);  // Next 10 bytes

// Take (consume) bytes
const byte = try reader.takeByte();
const data = try reader.take(10);

// Skip bytes
reader.toss(10);  // Advance position by 10

// Read into your buffer
var my_buffer: [100]u8 = undefined;
try reader.readSliceAll(&my_buffer);

// Read integers (little/big endian)
const value = try reader.takeInt(u32, .little);

// Read structs (MUST use extern struct for binary layout!)
const my_struct = try reader.takeStruct(MyType, .little);

// Note: MyType must be defined as:
// const MyType = extern struct { ... };  // Not just 'struct'

// Delimiter-based reading
while (reader.takeDelimiterExclusive('\n')) |line| {
    // Process line...
} else |err| switch (err) {
    error.EndOfStream => break,
    error.StreamTooLong => return err,  // Line didn't fit in buffer
    error.ReadFailed => return err,
}

// Stream data to a writer
const bytes_copied = try reader.stream(&writer, .unlimited);
try reader.streamExact(&writer, 1024);  // Exactly 1024 bytes

// Discard data efficiently (implementations can optimize)
const bytes_discarded = try reader.discard(.unlimited);
```

#### Buffer Management

```zig
// Check buffered data
const available = reader.bufferedLen();
const buffered_data = reader.buffered();

// Ensure buffer has enough data
try reader.fill(100);  // Ensure at least 100 bytes buffered

// Rebase buffer (manage internal state)
try reader.rebase(capacity);
```

### std.Io.Writer

#### Structure

```zig
pub const Writer = struct {
    vtable: *const VTable,
    buffer: []u8,
    end: usize,  // Write position in buffer
    
    // ... methods ...
};
```

#### Essential Writing Methods

```zig
// Write bytes
try writer.write("Hello, World!\n");
try writer.writeAll(data);  // Write all or error

// Write integers/structs
try writer.writeInt(u32, 42, .little);
try writer.writeStruct(my_struct, .little);  // Struct must be 'extern struct'

// Formatted printing
try writer.print("Value: {d}\n", .{42});

// Flush buffer to underlying stream
try writer.flush();

// Advanced: Vectored writes
try writer.writeVec(&[_][]const u8{"Hello", " ", "World"});

// Splatting (repeat byte without copying)
try writer.splat('=', 80);  // 80 equal signs, O(M) not O(M*N)

// Direct file-to-file transfer
try writer.sendFile(source_file);
```

#### Critical: Don't Forget to Flush!

```zig
pub fn writeData(writer: *std.Io.Writer) !void {
    try writer.write("Important data\n");
    try writer.flush();  // MUST FLUSH!
}
```

Without flushing, buffered data may never reach the destination!

---

## File Operations

> **🚨 CRITICAL API CHANGE (Zig 0.16)**: The `file.reader()` method signature has changed!
>
> **It now requires an `Io` parameter:**
> ```zig
> // ❌ OLD (pre-0.16):
> var file_reader = file.reader(&buffer);
>
> // ✅ NEW (0.16+):
> var file_reader = file.reader(io, &buffer);
> ```
>
> **However, `file.writer()` does NOT require `Io`:**
> ```zig
> // ✅ Still correct:
> var file_writer = file.writer(&buffer);
> ```
>
> This affects all file reading examples below. Make sure to pass the `io` parameter!

### Two File APIs

#### 1. **std.fs** - Traditional Synchronous API

```zig
// Opening files (no Io parameter needed)
const file = try std.fs.openFileAbsolute("/path/to/file.txt", .{});
defer file.close();

const cwd = std.fs.cwd();
const file2 = try cwd.openFile("relative/path.txt", .{});
defer file2.close();

// Create files
const new_file = try std.fs.cwd().createFile("output.txt", .{});
defer new_file.close();
```

#### 2. **std.Io.File** - Concurrency-Aware API

```zig
pub fn processFile(io: std.Io) !void {
    // Opening requires Io parameter
    const file = try std.Io.File.openAbsolute(io, "/path/to/file.txt", .{});
    defer file.close(io);  // Also requires Io!
    
    // Now file operations participate in the concurrency model
}
```

**Use `std.Io.File` when you want your code to be concurrency-model agnostic.**

### Creating Readers and Writers from Files

```zig
pub fn fileExample(io: std.Io) !void {
    const file = try std.fs.openFileAbsolute("/path/to/file.txt", .{});
    defer file.close();

    // Provide your own buffer!
    // IMPORTANT: file.reader() now requires io parameter!
    var read_buffer: [8192]u8 = undefined;
    var file_reader = file.reader(io, &read_buffer);

    // Access the std.Io.Reader interface
    const reader: *std.Io.Reader = &file_reader.interface;

    // For writing (does NOT require io parameter)
    var write_buffer: [8192]u8 = undefined;
    var file_writer = file.writer(&write_buffer);
    const writer: *std.Io.Writer = &file_writer.interface;
}
```

### std.Io.File.Reader vs std.Io.Reader - Common Confusion Point ⚠️

**This is a common source of confusion!** There are **two different Reader types** you'll encounter:

#### 1. `std.Io.File.Reader` - File-specific wrapper with enhanced features

```zig
pub const Reader = struct {
    io: Io,
    file: File,
    err: ?ReadError = null,
    mode: Mode = .positional,  // or .streaming
    pos: u64 = 0,              // Current position
    size: ?u64 = null,         // Cached file size
    size_err: ?SizeError = null,
    seek_err: ?SeekError = null,
    interface: std.Io.Reader,  // The actual Reader interface
};
```

**Key Features:**
- Memoizes file size from stat
- Tracks seek position
- Defaults to `.positional` mode (more thread-safe) with fallback to streaming
- Has file-specific methods like `seekTo()`, `seekBy()`, `getSize()`, `atEnd()`
- Supports direct fd-to-fd transfers (sendfile)

#### 2. `std.Io.Reader` - Generic reading interface

This is the **interface** that all readers implement. It has the actual reading methods like:
- `take()`, `peek()`, `readSliceAll()`, etc.
- Does **NOT** have seeking methods
- This is what you pass around in your code

#### The Pattern - Two-Step Process

```zig
pub fn readFromFile(io: std.Io, file: std.fs.File) !void {
    var buffer: [4096]u8 = undefined;

    // Step 1: Create File.Reader (has seeking, file-specific features)
    var file_reader = file.reader(io, &buffer);

    // Step 2: Get the Io.Reader interface for actual reading
    var reader = &file_reader.interface;

    // Use File.Reader methods for positioning
    try file_reader.seekTo(1024);
    const size = try file_reader.getSize();

    // Use Io.Reader methods for reading
    const data = try reader.take(100);
}
```

#### Common Mistake

```zig
// ❌ WRONG - trying to call seekTo on Io.Reader
var reader = &file_reader.interface;
try reader.seekTo(1024);  // ERROR! No such method on Io.Reader

// ✅ CORRECT - call seekTo on File.Reader, then read from interface
try file_reader.seekTo(1024);
var reader = &file_reader.interface;
const data = try reader.take(100);
```

#### Why This Design?

- `File.Reader` wraps the file handle and provides **file-specific operations**
- `Io.Reader` is a **generic interface** that works with any readable source
- The `.interface` field exposes the generic reading API
- This allows file readers to participate in the generic Reader/Writer ecosystem while keeping file-specific features accessible

### Buffer Sizing Guidelines

From "Don't Forget To Flush":

1. **For file I/O endpoints**: Sacrifice cache lines to batch syscalls (4KB-8KB typical)
2. **For intermediate streams**: Keep it simple, avoid accidental complexity
3. **For TLS/encryption**: Use maximum frame size (e.g., 16KB for TLS)
4. **Use short reads/writes**: Implementations can return partial results to simplify logic

```zig
// Good buffer sizes
var file_buffer: [8192]u8 = undefined;      // File I/O
var network_buffer: [4096]u8 = undefined;   // Network
var tls_buffer: [16384]u8 = undefined;      // TLS (max encrypted frame)
var parse_buffer: [256]u8 = undefined;      // Parsing small records
```

---

## Concurrency Patterns

### async vs concurrent

```zig
// async - Decouple call from return (may run on same thread)
var future = io.async(doWork, .{io});
try future.await(io);

// concurrent - MUST run simultaneously (spawns thread if needed)
var task = try io.concurrent(heavyWork, .{io});
try task.await(io);
```

**Key difference**: `concurrent` will fail with `error.ConcurrencyUnavailable` on single-threaded systems rather than deadlock!

### Futures and Awaiting

```zig
pub fn parallelProcessing(io: std.Io) !void {
    // Start multiple tasks
    var task1 = try io.concurrent(processFile, .{io, "file1.txt"});
    var task2 = try io.concurrent(processFile, .{io, "file2.txt"});
    var task3 = try io.concurrent(processFile, .{io, "file3.txt"});
    
    // Wait for results
    const result1 = try task1.await(io);
    const result2 = try task2.await(io);
    const result3 = try task3.await(io);
}
```

### Cancellation

```zig
pub fn timeoutExample(io: std.Io) !void {
    var task = try io.concurrent(longRunningWork, .{io});
    
    // Set up deferred cancellation
    defer task.cancel(io) catch {};
    
    // Do other work...
    
    // If we error out, task is automatically cancelled
    try someOtherOperation();
    
    // Otherwise wait for completion
    try task.await(io);
}
```

Cancellation propagates through the stack automatically with try!

### Queue - Go-Style Channels

```zig
pub fn producerConsumer(io: std.Io) !void {
    // Initialize queue with buffer
    var queue_buffer: [10][]const u8 = undefined;
    var queue: std.Io.Queue([]const u8) = .init(&queue_buffer);
    
    // Start producer
    var producer = try io.concurrent(produce, .{io, &queue});
    defer producer.cancel(io) catch {};
    
    // Start consumer
    var consumer = try io.concurrent(consume, .{io, &queue});
    defer consumer.cancel(io) catch {};
    
    // Wait for consumer to finish
    const result = try consumer.await(io);
}

fn produce(io: std.Io, queue: *std.Io.Queue([]const u8)) !void {
    try queue.putOne(io, "message 1");
    try queue.putOne(io, "message 2");
    try queue.putOne(io, "message 3");
}

fn consume(io: std.Io, queue: *std.Io.Queue([]const u8)) ![]const u8 {
    const msg1 = try queue.getOne(io);
    const msg2 = try queue.getOne(io);
    const msg3 = try queue.getOne(io);
    return msg3;  // Return last message
}
```

### Group - Managing Multiple Tasks

```zig
pub fn batchProcessing(io: std.Io, allocator: Allocator, files: [][]const u8) !void {
    // Group.init is a constant value
    var group: std.Io.Group = std.Io.Group.init;
    defer group.cancel(io);

    // Add tasks to group using .async()
    for (files) |file| {
        group.async(io, processFile, .{io, file});
    }

    // Wait for all to complete (does not return error)
    group.wait(io);

    // Or cancel all (already done by defer)
}
```

### Synchronization Primitives

```zig
// Mutex (init is a constant value, not a function)
var mutex: std.Io.Mutex = std.Io.Mutex.init;

try mutex.lock(io);
defer mutex.unlock(io);
// Critical section...

// Condition Variable (empty struct initialization)
var cond: std.Io.Condition = .{};

try cond.wait(io, &mutex);  // Wait for signal
cond.signal(io);             // Wake one waiter
cond.broadcast(io);          // Wake all waiters
```

### Select - Multiple Futures

```zig
pub fn selectExample(io: std.Io) !void {
    var task1 = try io.async(work1, .{io});
    var task2 = try io.async(work2, .{io});
    
    // Wait for first to complete
    var select: std.Io.Select = .init();
    select.add(&task1);
    select.add(&task2);
    
    const ready = try select.wait(io);
    // Handle whichever completed first...
}
```

### Time Operations

```zig
// Sleep (cancellable)
try io.sleep(std.Io.Duration.fromSeconds(1), .awake);

// Timeouts
const timeout = std.Io.Timeout.fromSeconds(5);
try io.sleepUntil(timeout, .awake);

// Clock and Duration (requires io parameter!)
const start = try std.Io.Clock.awake.now(io);
// ... work ...
const elapsed = try start.elapsed(io);
```

---

## Practical Examples

### Example 1: Reading a File Line by Line

```zig
pub fn readLines(io: std.Io, allocator: Allocator, path: []const u8) !void {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    // CRITICAL: file.reader() now requires io parameter!
    var buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &buffer);
    const reader = &file_reader.interface;

    // Allocating writer for line accumulation
    var line = std.Io.Writer.Allocating.init(allocator);
    defer line.deinit();

    while (true) {
        reader.streamDelimiter(&line.writer, '\n') catch |err| {
            if (err == error.EndOfStream) {
                // Handle any remaining data without newline
                if (line.written().len > 0) {
                    std.debug.print("Last line: {s}\n", .{line.written()});
                }
                break;
            }
            return err;
        };

        // Skip the newline
        reader.toss(1);

        // Process line
        std.debug.print("Line: {s}\n", .{line.written()});

        // Clear for next line
        line.clearRetainingCapacity();
    }
}
```

### Example 2: Concurrent Video Processing

```zig
pub fn processVideoBatch(io: std.Io, allocator: Allocator, files: [][]const u8) !void {
    var results = try allocator.alloc(ProcessResult, files.len);
    defer allocator.free(results);
    
    var tasks = try allocator.alloc(std.Io.Future(ProcessResult), files.len);
    defer allocator.free(tasks);
    
    // Start all processing tasks
    for (files, 0..) |file, i| {
        tasks[i] = try io.concurrent(processVideo, .{io, allocator, file});
    }
    
    // Wait for all results
    for (tasks, 0..) |*task, i| {
        results[i] = try task.await(io);
    }
    
    // Results ready!
}

fn processVideo(io: std.Io, allocator: Allocator, path: []const u8) !ProcessResult {
    const file = try std.Io.File.openAbsolute(io, path, .{});
    defer file.close(io);

    // CRITICAL: file.reader() requires io parameter!
    var buffer: [65536]u8 = undefined;  // 64KB for video data
    var file_reader = file.reader(io, &buffer);
    const reader = &file_reader.interface;

    // Process video data...
    var result: ProcessResult = .{};

    while (true) {
        const chunk = reader.take(4096) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        if (chunk.len == 0) break;

        // Process chunk...
        result.frames_processed += 1;
    }

    return result;
}
```

### Example 3: HTTP Server with Streaming

```zig
pub fn handleConnection(io: std.Io, stream: std.net.Stream) !void {
    defer stream.close();
    
    var read_buffer: [8192]u8 = undefined;
    var reader = stream.reader(&read_buffer);
    
    var write_buffer: [8192]u8 = undefined;
    var writer = stream.writer(&write_buffer);
    
    var server = std.http.Server.init(&reader.interface, &writer.interface);
    
    while (true) {
        var request = try server.receiveHead();
        
        // Handle request...
        try request.respond("Hello, World!", .{ .status = .ok });
        
        if (!request.head.keep_alive) break;
    }
}
```

### Example 4: Chained I/O Pipeline

```zig
pub fn compressAndSend(io: std.Io) !void {
    const input_file = try std.Io.File.openAbsolute(io, "/data/large.bin", .{});
    defer input_file.close(io);
    
    const output_file = try std.Io.File.openAbsolute(io, "/data/output.gz", .{ .mode = .write_only });
    defer output_file.close(io);
    
    // Chain: File -> Compression -> File
    var read_buf: [8192]u8 = undefined;
    var reader = input_file.reader(&read_buf);
    
    var compress_buf: [8192]u8 = undefined;
    var compressor = std.compress.gzip.compressor(&reader.interface, &compress_buf);
    
    var write_buf: [8192]u8 = undefined;
    var writer = output_file.writer(&write_buf);
    
    // Stream through pipeline
    try reader.interface.streamRemaining(&writer.interface);
    try writer.interface.flush();
}
```

---

## Migration from Old API

### Common Patterns

#### Old: Generic Reader

```zig
// OLD - Don't use this!
fn processData(reader: anytype) !void {
    var buffer: [1024]u8 = undefined;
    const bytes = try reader.read(&buffer);
    // ...
}
```

#### New: Concrete Reader

```zig
// NEW - Use this!
fn processData(reader: *std.Io.Reader) !void {
    const bytes = try reader.take(1024);
    // ...
}
```

#### Old: BufferedReader Wrapper

```zig
// OLD
var buffered = std.io.bufferedReader(file.reader());
const reader = buffered.reader();
```

#### New: Buffer in Interface

```zig
// NEW (0.16+ requires io parameter!)
pub fn newWay(io: std.Io, file: std.fs.File) !void {
    var buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &buffer);
    const reader = &file_reader.interface;
}
```

#### Old: readUntilDelimiterOrEof

```zig
// OLD
while (try reader.readUntilDelimiterOrEof(&buffer, '\n')) |line| {
    // process line
}
```

#### New: takeDelimiterExclusive

```zig
// NEW
while (reader.takeDelimiterExclusive('\n')) |line| {
    // process line
} else |err| switch (err) {
    error.EndOfStream => {},  // Normal end
    error.StreamTooLong => return err,
    error.ReadFailed => return err,
}
```

### Adapter for Legacy Code

If you have old writers/readers that you can't change:

```zig
fn useOldWriter(old_writer: anytype) !void {
    var adapter = old_writer.adaptToNewApi(&.{});
    const w: *std.Io.Writer = &adapter.new_interface;
    try w.print("{s}", .{"example"});
}
```

---

## Key Takeaways

1. **Always provide buffers explicitly** - No hidden allocations
2. **Pass `io: std.Io` for concurrency control** - Like passing allocators
3. **Buffer is above the vtable** - Performance optimization, compiler-friendly
4. **Use `std.Io.File` for concurrency-aware file ops** - Works with any Io implementation
5. **Don't forget to flush!** - Buffered data doesn't write itself
6. **async ≠ concurrent** - `async` decouples, `concurrent` parallelizes
7. **Cancellation propagates with try** - Proper error handling = proper cleanup
8. **Choose buffer sizes strategically**:
   - File I/O: 4KB-8KB (batch syscalls)
   - TLS: Max frame size (16KB)
   - Parsing: As small as needed (256B)

---

## Resources

- **Talk**: "Don't Forget To Flush" by Andrew Kelley (Systems Distributed 2025)
- **Article**: [Zig's New Async I/O (Text Version)](https://andrewkelley.me/post/zig-new-async-io-text-version.html)
- **Release Notes**: [Zig 0.15.1 Release Notes](https://ziglang.org/download/0.15.1/release-notes.html)
- **PR**: [std: Introduce Io Interface #25592](https://github.com/ziglang/zig/pull/25592)
- **Docs**: Use `zig std` to browse standard library documentation

---

## Version Info

This guide covers **Zig 0.15.1+** through **Zig 0.16.0-dev**.

**Tested on**: Zig `0.16.0-dev.1216+846854972` (November 2025)

### Important Breaking Changes in 0.16

- **`file.reader()` now requires `Io` parameter**: `file.reader(io, &buffer)`
- **`file.writer()` still works without `Io`**: `file.writer(&buffer)`
- **Limit enum**: Use `.unlimited` instead of `.max`
- **Mutex/Condition init**: `std.Io.Mutex.init` is a constant, not `.init()`
- **Group API**: Use `group.async()` not `group.add()`
- **Clock API**: `std.Io.Clock.awake.now(io)` requires io parameter

### Status

The full `std.Io` async/await features are available in 0.16.0-dev builds.

Some features (particularly `std.Io.Evented` on macOS) are still under active development.

Always check the latest documentation: `zig std` or [https://ziglang.org/documentation/master/std/](https://ziglang.org/documentation/master/std/)
