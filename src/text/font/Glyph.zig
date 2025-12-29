//! Glyph metrics and atlas location information

const Glyph = @This();

/// CoreText glyph ID
id: u16,

/// Glyph dimensions in pixels
width: u32,
height: u32,

/// Bearing offsets for positioning
bearing_x: i32,
bearing_y: i32,

/// Horizontal advance for cursor positioning
advance_x: f32,

/// Location in texture atlas (set after rasterization)
atlas_x: u32 = 0,
atlas_y: u32 = 0,
