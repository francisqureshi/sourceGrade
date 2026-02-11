const std = @import("std");

// ============================================================================
// Shared Types (platform-agnostic)
// ============================================================================

pub const RenderConfig = struct {
    use_display_p3: bool = true,
    use_10bit: bool = true,
};
