//! Vertex structure for text rendering
//! Each glyph quad uses 4 vertices (instanced rendering)

const TextVertex = @This();

/// Position of glyph in atlas texture (pixels)
glyph_pos: [2]u32 align(8),

/// Size of glyph in atlas texture (pixels)
glyph_size: [2]u32 align(8),

/// Glyph bearings (left, top)
bearings: [2]i16 align(4),

/// Screen position for this glyph (pixels)
screen_pos: [2]f32 align(8),

/// Text color (RGBA)
color: [4]u8 align(4),
