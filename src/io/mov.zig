const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

// ============================================================================
// Core Data Structures
// ============================================================================

/// Represents an atom's header (the 8-byte prefix)
pub const AtomHeader = struct {
    size: u64,
    type: [4]u8,
    size_field: u32,

    /// Total size including header
    pub fn totalSize(self: AtomHeader) u64 {
        return if (self.size == 0)
            std.math.maxInt(u64) // Extends to EOF
        else
            self.size;
    }

    /// Size of data payload (excluding 8-byte header)
    fn dataSize(self: AtomHeader) u64 {
        const header_size: u64 = if (self.size_field == 1)
            16 // Extended header  4 (size) + 4 (type) + 8 (ext size)
        else
            8; // Normal header    4 (size) + 4 (type)

        return if (self.size == 0)
            std.math.maxInt(u64) - header_size
        else
            self.size - header_size;
    }

    fn isContainer(self: AtomHeader) bool {
        const containers = [_][]const u8{
            "moov", "trak", "mdia", "minf", "stbl",
            "edts", "dinf", "udta", "meta",
        };

        for (containers) |container| {
            if (std.mem.eql(u8, &self.type, container)) {
                return true;
            }
        }
        return false;
    }
};

/// Sample size table data
pub const SampleSizeTable = struct {
    version: u8,
    flags: [3]u8,
    sample_size: u32, // If 0, sizes are in the array
    sample_count: u32,
    sizes: []u32, // Individual sample sizes (if sample_size == 0)

    fn deinit(self: SampleSizeTable, allocator: Allocator) void {
        if (self.sizes.len > 0) {
            allocator.free(self.sizes);
        }
    }
};

/// Sample to Chunk entry data
pub const StscEntry = struct {
    first_chunk: u32,
    samples_per_chunk: u32,
    sample_description_index: u32,
};

/// Sample Time To SampleBox entry data
pub const SttsEntry = struct {
    sample_count: u32,
    sample_duration: u32,
};

/// Media Header Box
pub const MediaHeader = struct {
    version: u8,
    flags: [3]u8,
    creation_time: u64,
    modification_time: u64,
    timescale: u32,
    duration: u64,
};

/// Track Header Box
pub const TrackHeader = struct {
    version: u8,
    flags: [3]u8,
    creation_time: u64,
    modification_time: u64,
    track_id: u32,
    duration: u64,
    width: u32, // 16.16 fixed point
    height: u32, // 16.16 fixed point

    pub fn getWidth(self: TrackHeader) f32 {
        return @as(f32, @floatFromInt(self.width)) / 65536.0;
    }

    pub fn getHeight(self: TrackHeader) f32 {
        return @as(f32, @floatFromInt(self.height)) / 65536.0;
    }
};

/// Video metadata extracted from stsd
pub const VideoInfo = struct {
    codec: [4]u8, // 'apch', 'apcn', etc.
    width: u16,
    height: u16,
    depth: u16,
};

pub const TimecodeInfo = struct {
    // Fram tmcd sample descriptio
    flags: TimecodeFlags,
    timescale: u32, // Usually same as media timescale
    frame_duration: u32,
    frames_per_second: u8,

    // The actual timecode value (read from mdat)
    frame_number: ?u32 = null,

    pub fn isDropFrame(self: TimecodeInfo) bool {
        return (self.flags & 0x00000001) != 0;
    }
};

// From the tmcd box in stsd (not mdat)
pub const TimecodeFlags = packed struct {
    drop_frame: bool, // bit 0: 0x00000001
    twenty_four_hour: bool, // bit 1: 0x00000002
    negative_ok: bool, // bit 2: 0x00000004
    counter: bool, // bit 3: 0x00000008
    _reserved: u28,
};

pub const TrackData = struct {
    sizes: ?[]const u32 = null,
    chunk_offsets: ?[]const u64 = null, // Note: might be u64 from co64!
    stsc_entries: ?[]const StscEntry = null,
    stts_entries: ?[]const SttsEntry = null,
    stsd_data: ?[]const u8 = null, // Raw codec info

    media_header: ?MediaHeader = null,
    track_header: ?TrackHeader = null,
    video_info: ?VideoInfo = null,
    timecode_info: ?TimecodeInfo = null,

    /// Return f32 framte rate - maybe switch to Rational
    pub fn getFrameRate(self: TrackData) ?f32 {
        const mdhd = self.media_header orelse return null;
        const stts = self.stts_entries orelse return null;

        if (stts.len == 0) return null;

        const frame_duration = stts[0].sample_duration;
        if (frame_duration == 0) return null;

        return @as(f32, @floatFromInt(mdhd.timescale)) / @as(f32, @floatFromInt(frame_duration));
    }

    pub fn deinit(self: *TrackData, allocator: Allocator) void {
        if (self.sizes) |s| allocator.free(s);
        if (self.chunk_offsets) |c| allocator.free(c);
        if (self.stsc_entries) |s| allocator.free(s);
        if (self.stts_entries) |s| allocator.free(s);
        if (self.stsd_data) |d| allocator.free(d);
    }
};

pub const FrameInfo = struct {
    offset: u64,
    size: u32,
};

// ============================================================================
// Atom Reading
// ============================================================================

/// Read just the atom header (8 bytes)
pub fn readAtomHeader(reader: *Io.Reader) !AtomHeader {
    const size_field = try reader.takeInt(u32, .big);
    const atom_type = try reader.takeArray(4);

    const actual_size: u64 = if (size_field == 1)
        try reader.takeInt(u64, .big)
    else
        size_field;

    return AtomHeader{
        .size = actual_size,
        .type = atom_type.*,
        .size_field = size_field,
    };
}

/// Read an atom's data into a buffer (you own the memory)
fn readAtomData(reader: *Io.Reader, allocator: Allocator, header: AtomHeader) ![]u8 {
    const data_size = header.dataSize();

    // Safety check for reasonable sizes
    if (data_size > 100 * 1024 * 1024) { // 100MB limit for metadata
        return error.AtomTooLarge;
    }

    const data = try allocator.alloc(u8, @intCast(data_size));
    errdefer allocator.free(data);

    try reader.readSliceAll(data);
    return data;
}

/// Skip an atom's data without reading it
fn skipAtomData(reader: *Io.Reader, header: AtomHeader) !void {
    const data_size = header.dataSize();
    try reader.discardAll(@intCast(data_size));
}

// ============================================================================
// Specific Atom Parsers
// ============================================================================

/// Parse the stsz (sample size table) atom
fn parseStsz(data: []const u8, allocator: Allocator) !SampleSizeTable {
    if (data.len < 12) return error.InvalidStszAtom;

    var fixed_reader = Io.Reader.fixed(data);
    const reader = &fixed_reader;

    const version = try reader.takeByte();
    const flags = try reader.takeArray(3);
    const sample_size = try reader.takeInt(u32, .big);
    const sample_count = try reader.takeInt(u32, .big);

    var sizes: []u32 = &.{}; // Empty slice by default

    if (sample_size == 0) {
        // Variable sizes - need to read the array
        sizes = try allocator.alloc(u32, sample_count);
        errdefer allocator.free(sizes);

        for (sizes) |*size| {
            size.* = try reader.takeInt(u32, .big);
        }
    }

    return SampleSizeTable{
        .version = version,
        .flags = flags.*,
        .sample_size = sample_size,
        .sample_count = sample_count,
        .sizes = sizes,
    };
}

/// Parse the stss (sync sample table - keyframes) atom
fn parseStss(data: []const u8, allocator: Allocator) ![]u32 {
    if (data.len < 8) return error.InvalidStssAtom;

    var fixed_reader = Io.Reader.fixed(data);
    const reader = &fixed_reader;

    _ = try reader.takeByte(); // version
    _ = try reader.takeArray(3); // flags

    const entry_count = try reader.takeInt(u32, .big);

    const keyframes = try allocator.alloc(u32, entry_count);
    errdefer allocator.free(keyframes);

    for (keyframes) |*frame| {
        frame.* = try reader.takeInt(u32, .big);
    }

    return keyframes;
}

/// Parse the stco (Chunk offset table - locations of frames in mdat) atom
fn parseStco(data: []const u8, allocator: Allocator) ![]u64 {
    if (data.len < 8) return error.InvalidStcoAtom;

    var fixed_reader = Io.Reader.fixed(data);
    const reader = &fixed_reader;

    _ = try reader.takeByte(); // version
    _ = try reader.takeArray(3); // flags

    const entry_count = try reader.takeInt(u32, .big);

    const chunk_offsets = try allocator.alloc(u64, entry_count);
    errdefer allocator.free(chunk_offsets);

    for (chunk_offsets) |*offset| {
        const offset_u32 = try reader.takeInt(u32, .big);
        offset.* = offset_u32;
    }

    return chunk_offsets;
}

/// Parse the co64 (64-bit chunk offset table) atom
fn parseCo64(data: []const u8, allocator: Allocator) ![]u64 {
    if (data.len < 8) return error.InvalidCo64Atom;

    var fixed_reader = Io.Reader.fixed(data);
    const reader = &fixed_reader;

    _ = try reader.takeByte(); // version
    _ = try reader.takeArray(3); // flags

    const entry_count = try reader.takeInt(u32, .big);

    const chunk_offsets = try allocator.alloc(u64, entry_count);
    errdefer allocator.free(chunk_offsets);

    for (chunk_offsets) |*offset| {
        offset.* = try reader.takeInt(u64, .big);
    }

    return chunk_offsets;
}

/// Parse the stsc (Sample to Chunk info - how frames are grouped into chunks) atom
fn parseStsc(data: []const u8, allocator: Allocator) ![]StscEntry {
    if (data.len < 8) return error.InvalidStscAtom;

    var fixed_reader = Io.Reader.fixed(data);
    const reader = &fixed_reader;

    _ = try reader.takeByte(); // version
    _ = try reader.takeArray(3); // flags

    const entry_count = try reader.takeInt(u32, .big);

    const stsc_entry = try allocator.alloc(StscEntry, entry_count);
    errdefer allocator.free(stsc_entry);

    for (stsc_entry) |*entry| {
        entry.*.first_chunk = try reader.takeInt(u32, .big);
        entry.*.samples_per_chunk = try reader.takeInt(u32, .big);
        entry.*.sample_description_index = try reader.takeInt(u32, .big);
    }

    return stsc_entry;
}

/// Parse the stts (TimeToSampleBox - the frame duration) atom
fn parseStts(data: []const u8, allocator: Allocator) ![]SttsEntry {
    if (data.len < 8) return error.InvalidSttsAtom;

    var fixed_reader = Io.Reader.fixed(data);
    const reader = &fixed_reader;

    _ = try reader.takeByte(); // version
    _ = try reader.takeArray(3); // flags

    const entry_count = try reader.takeInt(u32, .big);

    const stts_entry = try allocator.alloc(SttsEntry, entry_count);
    errdefer allocator.free(stts_entry);

    for (stts_entry) |*entry| {
        entry.*.sample_count = try reader.takeInt(u32, .big);
        entry.*.sample_duration = try reader.takeInt(u32, .big);
    }

    return stts_entry;
}

/// Parse mdhd (Media Header)
fn parseMdhd(data: []const u8) !MediaHeader {
    if (data.len < 24) return error.InvalidMdhdAtom;

    var fixed_reader = Io.Reader.fixed(data);
    const reader = &fixed_reader;

    const version = try reader.takeByte();
    const flags = try reader.takeArray(3);

    const creation_time: u64 = if (version == 1)
        try reader.takeInt(u64, .big)
    else
        try reader.takeInt(u32, .big);

    const modification_time: u64 = if (version == 1)
        try reader.takeInt(u64, .big)
    else
        try reader.takeInt(u32, .big);

    const timescale = try reader.takeInt(u32, .big);

    const duration: u64 = if (version == 1)
        try reader.takeInt(u64, .big)
    else
        try reader.takeInt(u32, .big);

    return MediaHeader{
        .version = version,
        .flags = flags.*,
        .creation_time = creation_time,
        .modification_time = modification_time,
        .timescale = timescale,
        .duration = duration,
    };
}

/// Parse tkhd (Track Header)
fn parseTkhd(data: []const u8) !TrackHeader {
    if (data.len < 84) return error.InvalidTkhdAtom;

    var fixed_reader = Io.Reader.fixed(data);
    const reader = &fixed_reader;

    const version = try reader.takeByte();
    const flags = try reader.takeArray(3);

    const creation_time: u64 = if (version == 1)
        try reader.takeInt(u64, .big)
    else
        try reader.takeInt(u32, .big);

    const modification_time: u64 = if (version == 1)
        try reader.takeInt(u64, .big)
    else
        try reader.takeInt(u32, .big);

    const track_id = try reader.takeInt(u32, .big);
    _ = try reader.takeInt(u32, .big); // reserved

    const duration: u64 = if (version == 1)
        try reader.takeInt(u64, .big)
    else
        try reader.takeInt(u32, .big);

    // Skip reserved, layer, alternate_group, volume, reserved
    try reader.discardAll(2 * 4 + 2 + 2 + 2 + 2);

    // Skip transformation matrix (9 * 4 bytes)
    try reader.discardAll(9 * 4);

    const width = try reader.takeInt(u32, .big);
    const height = try reader.takeInt(u32, .big);

    return TrackHeader{
        .version = version,
        .flags = flags.*,
        .creation_time = creation_time,
        .modification_time = modification_time,
        .track_id = track_id,
        .duration = duration,
        .width = width,
        .height = height,
    };
}

/// Parse stsd for video info (ProRes-specific)
fn parseStsdVideo(data: []const u8) !VideoInfo {
    if (data.len < 86) return error.InvalidStsdAtom; // Need at least through depth field

    var fixed_reader = Io.Reader.fixed(data);
    const reader = &fixed_reader;

    _ = try reader.takeByte(); // version
    _ = try reader.takeArray(3); // flags
    const entry_count = try reader.takeInt(u32, .big);

    if (entry_count == 0) return error.NoVideoEntries;

    // Read first entry
    const entry_size = try reader.takeInt(u32, .big);
    if (entry_size < 78) return error.InvalidVideoEntry; // Minimum for video sample entry

    const codec = try reader.takeArray(4);

    // Check if this is a video codec (not timecode or other)
    const is_video = !std.mem.eql(u8, codec, "tmcd");
    if (!is_video) return error.NotVideoTrack;

    // Skip reserved (6 bytes) + data_reference_index (2 bytes)
    try reader.discardAll(6 + 2);

    // Skip version, revision, vendor (can be vendor-specific for ProRes)
    _ = try reader.takeInt(u16, .big); // pre_version
    _ = try reader.takeInt(u16, .big); // revision
    _ = try reader.takeInt(u32, .big); // vendor

    // temporal_quality, spatial_quality
    _ = try reader.takeInt(u32, .big); // temporal (usually 0)
    _ = try reader.takeInt(u32, .big); // spatial (usually 1023)

    const width = try reader.takeInt(u16, .big);
    const height = try reader.takeInt(u16, .big);

    // Skip horiz/vert resolution (72 dpi = 0x00480000 in 16.16 fixed)
    try reader.discardAll(4 + 4);

    _ = try reader.takeInt(u32, .big); // data size (reserved, must be 0)

    _ = try reader.takeInt(u16, .big); // frame_count (usually 1)

    // Compressor name: 32 bytes (first byte is Pascal string length)
    try reader.discardAll(32);

    const depth = try reader.takeInt(u16, .big);

    // Color table ID (usually -1 = 0xFFFF for none)
    _ = try reader.takeInt(i16, .big);

    return VideoInfo{
        .codec = codec.*,
        .width = width,
        .height = height,
        .depth = depth,
    };
}

/// Parse timecode for timecode info
fn parseTimecodeInfo(data: []const u8) !TimecodeInfo {
    if (data.len < 38) return error.InvalidTmcdAtom;

    var fixed_reader = Io.Reader.fixed(data);
    const reader = &fixed_reader;

    _ = try reader.takeByte(); // version
    _ = try reader.takeArray(3); // flags
    const entry_count = try reader.takeInt(u32, .big);

    if (entry_count == 0) return error.NoTmcdEntries;

    // Read first entry
    const entry_size = try reader.takeInt(u32, .big);
    if (entry_size < 30) return error.InvalidTmcdEntry;

    const codec = try reader.takeArray(4);

    // Check if this is timecode
    const is_tmcd = std.mem.eql(u8, codec, "tmcd");
    if (!is_tmcd) return error.NotTmcdTrack;

    // Skip reserved (6 bytes) + data_reference_index (2 bytes)
    try reader.discardAll(6 + 2);

    // Now read the timecode-specific fields
    _ = try reader.takeInt(u32, .big); // reserved (4 bytes)
    const flags_u32 = try reader.takeInt(u32, .big); // Drop frame flag, etc.
    const flags: TimecodeFlags = @bitCast(flags_u32);
    const timescale = try reader.takeInt(u32, .big);
    const frame_duration = try reader.takeInt(u32, .big);
    const frames_per_second = try reader.takeByte();
    _ = try reader.takeByte(); // reserved

    return TimecodeInfo{
        .flags = flags,
        .timescale = timescale,
        .frame_duration = frame_duration,
        .frames_per_second = frames_per_second,
        .frame_number = null, // Will be filled in when we read the actual sample
    };
}

// ============================================================================
// Recursive Atom Walker
// ============================================================================

/// Context for walking through atoms
const WalkContext = struct {
    allocator: Allocator,
    depth: u32,
    verbose: bool,
    on_stsz: ?*const fn (SampleSizeTable) void = null,
    on_stss: ?*const fn ([]const u32) void = null,
    on_stco: ?*const fn ([]const u64) void = null,
    on_co64: ?*const fn ([]const u64) void = null,
    on_stsc: ?*const fn ([]const StscEntry) void = null,
    on_stts: ?*const fn ([]const SttsEntry) void = null,
    track_data: *TrackData,
    all_tracks: *std.ArrayList(TrackData),
};

/// Walk through atoms, calling handlers for specific types
fn walkAtoms(
    reader: *Io.Reader,
    allocator: Allocator,
    parent_size: u64,
    ctx: WalkContext,
) !void {
    var bytes_read: u64 = 0;

    while (bytes_read < parent_size) {

        // Safety: Check if we have enough bytes left for a header
        if (parent_size - bytes_read < 8) {
            break;
        }

        const header = try readAtomHeader(reader);

        // Safety: Validate atom type is printable ASCII - essentally ignores
        // 'wide' padding box/atms
        for (header.type) |c| {
            if (c < 32 or c > 126) {
                // Invalid atom type - probably hit garbage/padding
                return; // Stop parsing this container
            }
        }

        // Safety: Check size is reasonable
        if (header.totalSize() > parent_size - bytes_read) {
            // Atom claims to be bigger than remaining space
            return; // Stop parsing
        }

        // Print with indentation (only if verbose)
        if (ctx.verbose) {
            printIndented(ctx.depth, "Atom: {s} ({d} bytes)\n", .{
                header.type,
                header.totalSize(),
            });
        }

        if (header.size == 0) {
            // Extends to EOF - stop processing
            break;
        }

        const data_size = header.dataSize();

        // Handle specific atom types
        if (std.mem.eql(u8, &header.type, "stsz")) {
            const data = try readAtomData(reader, allocator, header);
            defer allocator.free(data);

            const stsz = try parseStsz(data, allocator);

            // Only store if it has actual samples
            if (stsz.sizes.len > 0) {
                ctx.track_data.sizes = stsz.sizes;
            }

            if (ctx.on_stsz) |handler| {
                handler(stsz);
            }
        } else if (std.mem.eql(u8, &header.type, "stss")) {
            const data = try readAtomData(reader, allocator, header);
            defer allocator.free(data);

            const keyframes = try parseStss(data, allocator);
            defer allocator.free(keyframes);

            if (ctx.on_stss) |handler| {
                handler(keyframes);
            }
        } else if (std.mem.eql(u8, &header.type, "stco")) {
            const data = try readAtomData(reader, allocator, header);
            defer allocator.free(data);

            const chunk_offsets = try parseStco(data, allocator);
            ctx.track_data.chunk_offsets = chunk_offsets;

            if (ctx.on_stco) |handler| {
                handler(chunk_offsets);
            }
        } else if (std.mem.eql(u8, &header.type, "co64")) {
            const data = try readAtomData(reader, allocator, header);
            defer allocator.free(data);

            const chunk_offsets = try parseCo64(data, allocator);
            ctx.track_data.chunk_offsets = chunk_offsets;

            if (ctx.on_stco) |handler| {
                handler(chunk_offsets);
            }
        } else if (std.mem.eql(u8, &header.type, "stsc")) {
            const data = try readAtomData(reader, allocator, header);
            defer allocator.free(data);

            const stsc_entries = try parseStsc(data, allocator);
            ctx.track_data.stsc_entries = stsc_entries;

            if (ctx.on_stsc) |handler| {
                handler(stsc_entries);
            }
        } else if (std.mem.eql(u8, &header.type, "stts")) {
            const data = try readAtomData(reader, allocator, header);
            defer allocator.free(data);

            const stts = try parseStts(data, allocator);
            ctx.track_data.stts_entries = stts;

            if (ctx.on_stts) |handler| {
                handler(stts);
            }
        } else if (std.mem.eql(u8, &header.type, "mdhd")) {
            const data = try readAtomData(reader, allocator, header);
            defer allocator.free(data);

            const mdhd = try parseMdhd(data);
            ctx.track_data.media_header = mdhd;

            if (ctx.verbose) {
                std.debug.print("      [Media Header] timescale={d},  duration={d}\n", .{ mdhd.timescale, mdhd.duration });
            }
        } else if (std.mem.eql(u8, &header.type, "tkhd")) {
            const data = try readAtomData(reader, allocator, header);
            defer allocator.free(data);

            const tkhd = try parseTkhd(data);
            ctx.track_data.track_header = tkhd;

            if (ctx.verbose) {
                std.debug.print("      [Track Header] {}x{}, track_id={d}\n", .{ tkhd.getWidth(), tkhd.getHeight(), tkhd.track_id });
            }
        } else if (std.mem.eql(u8, &header.type, "stsd")) {
            const data = try readAtomData(reader, allocator, header);
            ctx.track_data.stsd_data = data;

            // Try to parse video info first
            if (parseStsdVideo(data)) |video_info| {
                ctx.track_data.video_info = video_info;

                if (ctx.verbose) {
                    std.debug.print("      [Video Info] {s} {}x{} depth={d}\n", .{
                        video_info.codec,
                        video_info.width,
                        video_info.height,
                        video_info.depth,
                    });
                }
            } else |video_err| {
                // Not a video track, try timecode
                if (parseTimecodeInfo(data)) |timecode_info| {
                    ctx.track_data.timecode_info = timecode_info;

                    if (ctx.verbose) {
                        std.debug.print("      [Timecode Info] fps={d}, timescale={d}, frame_duration={d}\n", .{
                            timecode_info.frames_per_second,
                            timecode_info.timescale,
                            timecode_info.frame_duration,
                        });
                    }
                } else |tc_err| {
                    if (ctx.verbose) {
                        std.debug.print("      Failed to parse as video ({}) or timecode ({})\n", .{ video_err, tc_err });
                    }
                }
            }

            if (ctx.verbose) {
                std.debug.print("      stored raw stsd data ({d} bytes)\n", .{data.len});
            }
        } else if (header.isContainer()) {
            // Special handling for trak atoms
            if (std.mem.eql(u8, &header.type, "trak")) {
                //Recursively walk children
                var new_track = TrackData{};
                var child_ctx = ctx;

                child_ctx.depth += 1;
                child_ctx.track_data = &new_track;

                try walkAtoms(reader, allocator, data_size, child_ctx);

                if (new_track.sizes != null or new_track.chunk_offsets != null) {
                    try ctx.all_tracks.append(allocator, new_track);
                } else {
                    new_track.deinit(allocator);
                }
            } else {
                // Regular container - just recurse
                var child_ctx = ctx;
                child_ctx.depth += 1;
                try walkAtoms(reader, allocator, data_size, child_ctx);
            }
        } else if (std.mem.eql(u8, &header.type, "wide")) {
            // Padding atom - skip
            try skipAtomData(reader, header);
        } else {
            // Skip unknown/uninteresting atoms
            try skipAtomData(reader, header);
        }

        bytes_read += header.totalSize();
    }
}

// ============================================================================
// Frame Index
// ============================================================================

pub fn buildFrameIndex(
    allocator: Allocator,
    sizes: []const u32, // from stsz
    chunk_offsets: []const u64, // from stco/co64
    stsc_entries: []const StscEntry,
) ![]FrameInfo {
    var frames = try allocator.alloc(FrameInfo, sizes.len);
    errdefer allocator.free(frames);

    var sample_index: usize = 0; // Which frame we're on

    // For each chunk...
    for (chunk_offsets, 0..) |chunk_offset, chunk_index| {
        // 1. Figure out how many samples THIS chunk has
        const chunk_number: u32 = @intCast(chunk_index + 1); // MOV uses 1-indexed chunks
        var samples_in_chunk: u32 = 0;

        // Find the last entry where first_chunk <= chunk_number
        var i = stsc_entries.len;
        while (i > 0) {
            i -= 1;
            if (stsc_entries[i].first_chunk <= chunk_number) {
                samples_in_chunk = stsc_entries[i].samples_per_chunk;
                break;
            }
        }
        var offset_in_chunk = chunk_offset;

        // 2. For each sample in this chunk...
        for (0..samples_in_chunk) |_| {
            frames[sample_index] = .{
                .offset = offset_in_chunk,
                .size = sizes[sample_index],
            };

            // 3. Next frame starts after this one
            offset_in_chunk += sizes[sample_index];
            sample_index += 1;
        }
    }

    return frames;
}

// ============================================================================
// Frame Extraction
// ============================================================================
/// Extract a single frame's data from the file
pub fn extractFrame(
    io: Io,
    file: Io.File,
    frame_info: FrameInfo,
    allocator: Allocator,
) ![]u8 {
    // std.Io.File.Reader.seekTo also can facilitate a positional read via:

    var buffer: [16384]u8 = undefined;
    var file_reader = file.reader(io, &buffer);

    try file_reader.seekTo(frame_info.offset);

    // Now get the reader interface for actual reading part...
    var reader = &file_reader.interface;

    const frame_data = try reader.readAlloc(allocator, frame_info.size);

    return frame_data;

    // Leaving this here for my own sanity ...
    // std.Io.File.Reader is NOT the same std.Io.Reader!!
    //
    //
    // var frame_data = try allocator.alloc(u8, frame_info.size);
    // errdefer allocator.free(frame_data);

    // Read from file at the exact offset

    // No worky!!! :
    // errors with 'error: expected type '[][]u8', found '[]u8'`' even though it requires a []u8 buffer...
    // _ = try file.readPositional(io, frame_data, frame_info.offset);

    // Worky: feels wrong ?
    // direct use of vtable with single element array of slices to match
    // the vtable's [][]u8 parameter for vectored I/O

    // var buffers = [_][]u8{frame_data};
    // _ = try io.vtable.fileReadPositional(io.userdata, file, &buffers, frame_info.offset);

}

/// Extract timecode frame number (u32) from file
pub fn extractTimecode(
    io: Io,
    file: Io.File,
    offset: u64,
) !u32 {
    var buffer: [4]u8 = undefined;
    var file_reader = file.reader(io, &buffer);

    try file_reader.seekTo(offset);

    var reader = &file_reader.interface;
    const frame_number = try reader.takeInt(u32, .big);

    return frame_number;
}

// ============================================================================
// Utilities
// ============================================================================

fn printIndented(depth: u32, comptime fmt: []const u8, args: anytype) void {
    var i: u32 = 0;
    while (i < depth) : (i += 1) {
        std.debug.print("    ", .{});
    }
    std.debug.print(fmt, args);
}

// ============================================================================
// High-Level API
// ============================================================================

// /// Parse a MOV/MP4 file and extract frame information
// pub fn parseMovFile(
//     io: Io,
//     allocator: Allocator,
//     filepath: []const u8,
// ) ![]TrackData {
//     return parseMovFileVerbose(io, allocator, filepath, false);
// }

/// Parse a MOV/MP4 file with optional verbose logging
pub fn parseMovFile(
    io: Io,
    allocator: Allocator,
    file: std.Io.File,
    verbose: bool,
) ![]TrackData {
    const stat = try file.stat(io);
    const file_size = stat.size;

    if (verbose) {
        std.debug.print("File Size: {d} bytes\n", .{file_size});
        std.debug.print("{s}\n", .{"=" ** 60});
    }
    // Create reader with reasonable buffer
    var buffer: [8192]u8 = undefined;
    var file_reader = file.reader(io, &buffer);
    const reader = &file_reader.interface;

    var all_tracks: std.ArrayList(TrackData) = .{};
    errdefer {
        for (all_tracks.items) |*track| {
            track.deinit(allocator);
        }
        all_tracks.deinit(allocator);
    }

    var dummy_track = TrackData{}; // Won't be used, but needed for ctx
    defer dummy_track.deinit(allocator);

    // Set up handlers (only in verbose mode)
    const ctx = WalkContext{
        .allocator = allocator,
        .depth = 0,
        .verbose = verbose,
        .on_stsz = if (verbose) &handleStsz else null,
        .on_stss = if (verbose) &handleStss else null,
        .on_stco = if (verbose) &handleStco else null,
        .on_stsc = if (verbose) &handleStsc else null,
        .on_stts = if (verbose) &handleStts else null,
        .track_data = &dummy_track,
        .all_tracks = &all_tracks,
    };

    // Walk all atoms
    try walkAtoms(reader, allocator, file_size, ctx);

    // Print and process all tracks (only in verbose mode)
    if (verbose) {
        for (all_tracks.items, 0..) |track, i| {
            std.debug.print("\n=== Track {d} ===\n", .{i});

            if (track.sizes) |sizes| {
                std.debug.print("  Sample count: {d}\n", .{sizes.len});
            }
            if (track.chunk_offsets) |offsets| {
                std.debug.print("  Chunk count: {d}\n", .{offsets.len});
            }
            if (track.stsc_entries) |entries| {
                std.debug.print("  STSC entries: {d}\n", .{entries.len});
            }

            // Build frame index if we have the required data
            if (track.sizes != null and
                track.chunk_offsets != null and
                track.stsc_entries != null)
            {
                std.debug.print("\n  Building Frame Index...\n", .{});
                const frames = try buildFrameIndex(
                    allocator,
                    track.sizes.?,
                    track.chunk_offsets.?,
                    track.stsc_entries.?,
                );
                defer allocator.free(frames);

                // Print first 10 frames
                const max_to_show = @min(10, frames.len);
                for (frames[0..max_to_show], 0..) |frame, frame_idx| {
                    std.debug.print("  Frame {d}: offset={d}, size={d}\n", .{ frame_idx, frame.offset, frame.size });
                }
                if (frames.len > 10) {
                    std.debug.print("  ... ({d} more frames)\n\n", .{frames.len - 10});
                }

                // Frame extraction
                var x: u32 = 0;
                while (x < 10) : (x += 1) {
                    const read_frame = try extractFrame(io, file, frames[x], allocator);
                    defer allocator.free(read_frame);

                    std.debug.print("  Extracted frame {d}: {d} bytes\n", .{ x, read_frame.len });
                    std.debug.print("  First 16 bytes: ", .{});
                    for (read_frame[0..@min(16, read_frame.len)]) |byte| {
                        std.debug.print("{x:0>2} ", .{byte});
                    }
                    std.debug.print("\n", .{});
                }
            }

            // Extract timecode if this is a timecode track
            if (track.timecode_info) |_| {
                if (track.chunk_offsets) |offsets| {
                    if (offsets.len > 0) {
                        const tc_frame_number = try extractTimecode(io, file, offsets[0]);
                        all_tracks.items[i].timecode_info.?.frame_number = tc_frame_number;

                        if (verbose) {
                            std.debug.print("  Timecode: {d} (raw frame number)\n", .{tc_frame_number});
                        }
                    }
                }
            }
        }
    } else {
        // Non-verbose mode: still need to extract timecode
        for (all_tracks.items, 0..) |track, i| {
            if (track.timecode_info) |_| {
                if (track.chunk_offsets) |offsets| {
                    if (offsets.len > 0) {
                        const tc_frame_number = try extractTimecode(io, file, offsets[0]);
                        all_tracks.items[i].timecode_info.?.frame_number = tc_frame_number;
                    }
                }
            }
        }
    }

    // Return the tracks (caller owns the memory)
    return all_tracks.toOwnedSlice(allocator);
}

// ============================================================================
// Handlers
// ============================================================================

fn handleStsz(stsz: SampleSizeTable) void {
    std.debug.print("\n>>> Found Sample Size Table <<<\n", .{});
    std.debug.print("  Version: {d}\n", .{stsz.version});
    std.debug.print("  Sample count: {d}\n", .{stsz.sample_count});

    if (stsz.sample_size != 0) {
        std.debug.print("  Fixed sample size: {d} bytes\n", .{stsz.sample_size});
    } else {
        std.debug.print("  Variable sizes: ", .{});
        const max_samples_to_show = @min(10, stsz.sizes.len);
        for (stsz.sizes[0..max_samples_to_show]) |size| {
            std.debug.print("{d}, ", .{size});
        }
        if (stsz.sizes.len > 10) {
            std.debug.print("... ({d} more)", .{stsz.sizes.len - 10});
        }
        std.debug.print("\n", .{});

        // Calculate statistics
        var min: u32 = std.math.maxInt(u32);
        var max: u32 = 0;
        var total: u64 = 0;

        for (stsz.sizes) |size| {
            min = @min(min, size);
            max = @max(max, size);
            total += size;
        }

        const avg = total / stsz.sizes.len;
        std.debug.print("  Size range: {d} - {d} bytes (avg: {d})\n", .{ min, max, avg });
    }
    std.debug.print("\n", .{});
}

fn handleStss(keyframes: []const u32) void {
    std.debug.print("\n>>> Found Sync Sample Table (Keyframes) <<<\n", .{});
    std.debug.print("  Keyframe count: {d}\n", .{keyframes.len});
    std.debug.print("  Keyframe indices: ", .{});

    const max_to_show = @min(10, keyframes.len);
    for (keyframes[0..max_to_show]) |frame| {
        std.debug.print("{d}, ", .{frame});
    }
    if (keyframes.len > 10) {
        std.debug.print("... ({d} more)", .{keyframes.len - 10});
    }
    std.debug.print("\n\n", .{});
}

fn handleStco(chunk_offsets: []const u64) void {
    std.debug.print("\n>>> Found Chunk Offset Box Table (frame locations in mdat)  <<<\n", .{});
    std.debug.print("  Chunk Offsets count: {d}\n", .{chunk_offsets.len});
    std.debug.print("  Chunk indices: ", .{});

    const max_to_show = @min(10, chunk_offsets.len);
    for (chunk_offsets[0..max_to_show]) |frame| {
        std.debug.print("{d}, ", .{frame});
    }
    if (chunk_offsets.len > 10) {
        std.debug.print("... ({d} more)", .{chunk_offsets.len - 10});
    }
    std.debug.print("\n\n", .{});
}

fn handleCo64(chunk_offsets: []const u64) void {
    std.debug.print("\n>>> Found Chunk Offset 'co64' Box Table (frame locations in mdat)  <<<\n", .{});
    std.debug.print("  Chunk Offsets count: {d}\n", .{chunk_offsets.len});
    std.debug.print("  Chunk indices: ", .{});

    const max_to_show = @min(10, chunk_offsets.len);
    for (chunk_offsets[0..max_to_show]) |frame| {
        std.debug.print("{d}, ", .{frame});
    }
    if (chunk_offsets.len > 10) {
        std.debug.print("... ({d} more)", .{chunk_offsets.len - 10});
    }
    std.debug.print("\n\n", .{});
}

fn handleStsc(entries: []const StscEntry) void {
    std.debug.print("\n>>> Sample to Chunk Entry (how frames are grouped into chunks)  <<<\n", .{});
    std.debug.print("  Chunk Offsets count: {d}\n", .{entries.len});
    std.debug.print("  Chunk indices: ", .{});

    for (entries, 0..) |entry, i| {
        std.debug.print("Entry: {d} chunk {d} -> {d} samples/chunk (desc index: {d})\n", .{
            i,
            entry.first_chunk,
            entry.samples_per_chunk,
            entry.sample_description_index,
        });
    }
    std.debug.print("\n\n", .{});
}

fn handleStts(entries: []const SttsEntry) void {
    std.debug.print("\n>>> Time To Sample Box (Frame Durations)  <<<\n", .{});
    std.debug.print("   count: {d}\n", .{entries.len});
    std.debug.print("   indices: ", .{});

    for (entries, 0..) |entry, i| {
        std.debug.print("  Entry {d}: {d} samples × {d} duration\n", .{
            i,
            entry.sample_count,
            entry.sample_duration,
        });
    }
    std.debug.print("\n\n", .{});
}

// ============================================================================
// Main Entry Point
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    const io = threaded.io();

    var argv = try std.process.argsWithAllocator(allocator);
    defer argv.deinit();

    _ = argv.next();
    const filepath = argv.next() orelse {
        std.debug.print("Usage: mov_parser <file.mov> [-v]\n", .{});
        return error.MissingArgument;
    };

    const verbose = if (argv.next()) |arg| std.mem.eql(u8, arg, "-v") else false;

    // Open file
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path = try std.fs.cwd().realpath(filepath, &path_buf);

    const file = try Io.File.openAbsolute(io, abs_path, .{});
    defer file.close(io);

    const tracks = try parseMovFile(io, allocator, file, verbose);
    defer {
        for (tracks) |*track| {
            track.deinit(allocator);
        }
        allocator.free(tracks);
    }

    for (tracks) |track| {
        // std.debug.print("track: {any}\n", .{track});
        if (track.video_info) |vi| {
            std.debug.print("Codec: {s}\n", .{vi.codec});
            std.debug.print("Resolution: {d}x{d}\n", .{ vi.width, vi.height });

            if (track.getFrameRate()) |fps| {
                std.debug.print("Frame Rate: {d:.2} fps\n", .{fps});
            }
        }

        // Print timecode if available
        if (track.timecode_info) |tc_info| {
            if (tc_info.frame_number) |frame_num| {
                std.debug.print("Timecode: {d} (raw frame number)\n", .{frame_num});
            }
            std.debug.print("TC Flags: \n{any}\n", .{tc_info.flags});
            std.debug.print("Frame duration: {d}\n", .{tc_info.frame_duration});
            std.debug.print("Timescale: {d}\n", .{tc_info.timescale});
            std.debug.print("FPS: {d}\n", .{tc_info.frames_per_second});
        }
    }
}
