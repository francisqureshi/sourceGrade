pub const packages = struct {
    pub const @"system_sdk-0.3.0-dev-alwUNnYaaAJAtIdE2fg4NQfDqEKs7QCXy_qYukAOBfmF" = struct {
        pub const build_root = "/Users/fq/.cache/zig/p/system_sdk-0.3.0-dev-alwUNnYaaAJAtIdE2fg4NQfDqEKs7QCXy_qYukAOBfmF";
        pub const build_zig = @import("system_sdk-0.3.0-dev-alwUNnYaaAJAtIdE2fg4NQfDqEKs7QCXy_qYukAOBfmF");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
    pub const @"zglfw-0.10.0-dev-zgVDNMacIQA-k7kNSfwUc9Lfzx-bb_wklVm25K-p8Tr7" = struct {
        pub const build_root = "/Users/fq/.cache/zig/p/zglfw-0.10.0-dev-zgVDNMacIQA-k7kNSfwUc9Lfzx-bb_wklVm25K-p8Tr7";
        pub const build_zig = @import("zglfw-0.10.0-dev-zgVDNMacIQA-k7kNSfwUc9Lfzx-bb_wklVm25K-p8Tr7");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "system_sdk", "system_sdk-0.3.0-dev-alwUNnYaaAJAtIdE2fg4NQfDqEKs7QCXy_qYukAOBfmF" },
        };
    };
    pub const @"zigglgen-0.4.0-bmyqLX_gLQDFXilQ5VQ9fJeOHKU1RFrggOzRqTGBX79W" = struct {
        pub const build_root = "/Users/fq/.cache/zig/p/zigglgen-0.4.0-bmyqLX_gLQDFXilQ5VQ9fJeOHKU1RFrggOzRqTGBX79W";
        pub const build_zig = @import("zigglgen-0.4.0-bmyqLX_gLQDFXilQ5VQ9fJeOHKU1RFrggOzRqTGBX79W");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
    pub const @"zm-0.3.0-cLX-WbfMAAAlqyfozvJsnhWlHO1MdlkVajyEDi6OISgO" = struct {
        pub const build_root = "/Users/fq/.cache/zig/p/zm-0.3.0-cLX-WbfMAAAlqyfozvJsnhWlHO1MdlkVajyEDi6OISgO";
        pub const build_zig = @import("zm-0.3.0-cLX-WbfMAAAlqyfozvJsnhWlHO1MdlkVajyEDi6OISgO");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "zigglgen", "zigglgen-0.4.0-bmyqLX_gLQDFXilQ5VQ9fJeOHKU1RFrggOzRqTGBX79W" },
    .{ "zm", "zm-0.3.0-cLX-WbfMAAAlqyfozvJsnhWlHO1MdlkVajyEDi6OISgO" },
    .{ "zglfw", "zglfw-0.10.0-dev-zgVDNMacIQA-k7kNSfwUc9Lfzx-bb_wklVm25K-p8Tr7" },
};
