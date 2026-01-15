const std = @import("std");
const metal = @import("metal");

/// High level multiGPU interface.
pub const GPU = struct {
    metal_device: metal.MetalDevice,
};
