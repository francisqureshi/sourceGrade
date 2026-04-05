const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const SourceMedia = @import("../media/media.zig").SourceMedia;
const Resolution = @import("../units.zig").Resolution;
const Rational = @import("../units.zig").Rational;

pub const Segment = struct {};
