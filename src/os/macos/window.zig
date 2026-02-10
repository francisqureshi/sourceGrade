const std = @import("std");
// const metal = @import("metal");

// C bridge for Swift window
const c = @cImport({
    @cInclude("metal_window.h");
});


