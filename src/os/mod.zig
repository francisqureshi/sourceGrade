const builtin = @import("builtin");

pub const Platform = switch (builtin.os.tag) {
    .macos => @import("macos/mod.zig").Platform,
    .linux => @import("linux/mod.zig").Platform,
    else => @compileError("Unsupported platform: " ++ @tagName(builtin.os.tag)),
};
