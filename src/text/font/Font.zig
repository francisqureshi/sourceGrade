//! Font face wrapper using CoreText

const Font = @This();

const std = @import("std");
const ct = @import("../coretext.zig");
const Glyph = @import("Glyph.zig");

/// CoreText font reference
ct_font: ct.CTFontRef,

/// Font size in points
size: f32,

pub fn init(name: [:0]const u8, size: f32) !Font {
    const cf_name = ct.createCFString(name) orelse return error.CFStringCreateFailed;
    defer ct.releaseCF(cf_name);

    const ct_font = ct.CTFontCreateWithName(
        cf_name,
        @floatCast(size),
        null,
    ) orelse return error.FontNotFound;

    return .{
        .ct_font = ct_font,
        .size = size,
    };
}

pub fn deinit(self: *Font) void {
    ct.releaseCF(self.ct_font);
}

/// Get glyph ID for a Unicode codepoint
pub fn getGlyphID(self: *Font, codepoint: u21) !u16 {
    const chars = [_]u16{@intCast(codepoint)};
    var glyphs: [1]u16 = undefined;

    if (!ct.CTFontGetGlyphsForCharacters(
        self.ct_font,
        &chars,
        &glyphs,
        1,
    )) return error.GlyphNotFound;

    return glyphs[0];
}

/// Get glyph metrics for a glyph ID
pub fn getGlyphMetrics(self: *Font, glyph_id: u16) !Glyph {
    const glyphs = [_]u16{glyph_id};
    var bounds: [1]ct.CGRect = undefined;
    var advances: [1]ct.CGSize = undefined;

    // Get bounding rect
    _ = ct.CTFontGetBoundingRectsForGlyphs(
        self.ct_font,
        ct.kCTFontOrientationHorizontal,
        &glyphs,
        &bounds,
        1,
    );

    // Get advance
    _ = ct.CTFontGetAdvancesForGlyphs(
        self.ct_font,
        ct.kCTFontOrientationHorizontal,
        &glyphs,
        &advances,
        1,
    );

    const rect = bounds[0];
    const advance = advances[0];

    return Glyph{
        .id = glyph_id,
        .width = @intFromFloat(@ceil(rect.size.width)),
        .height = @intFromFloat(@ceil(rect.size.height)),
        .bearing_x = @intFromFloat(@floor(rect.origin.x)),
        .bearing_y = @intFromFloat(@floor(rect.origin.y)),
        .advance_x = @floatCast(advance.width),
    };
}

/// Render a glyph into a grayscale buffer
/// Buffer must be width * height bytes
pub fn renderGlyph(
    self: *Font,
    glyph_id: u16,
    buffer: []u8,
    width: u32,
    height: u32,
) !void {
    if (buffer.len < width * height) return error.BufferTooSmall;

    // Get bounding rect to account for glyph origin offset
    const glyphs = [_]u16{glyph_id};
    var bounds: [1]ct.CGRect = undefined;
    _ = ct.CTFontGetBoundingRectsForGlyphs(
        self.ct_font,
        ct.kCTFontOrientationHorizontal,
        &glyphs,
        &bounds,
        1,
    );
    const rect = bounds[0];

    // Create grayscale color space
    const color_space = ct.CGColorSpaceCreateDeviceGray() orelse
        return error.ColorSpaceCreateFailed;
    defer ct.releaseCF(color_space);

    // Create bitmap context
    const context = ct.CGBitmapContextCreate(
        buffer.ptr,
        width,
        height,
        8, // 8 bits per component
        width, // bytes per row
        color_space,
        ct.kCGImageAlphaNone,
    ) orelse return error.ContextCreateFailed;
    defer ct.releaseCF(context);

    // Clear to black (transparent)
    ct.CGContextClearRect(context, .{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = @floatFromInt(width), .height = @floatFromInt(height) },
    });

    // Set white fill color for glyph
    ct.CGContextSetGrayFillColor(context, 1.0, 1.0);

    // Set text matrix (flip Y coordinate)
    ct.CGContextSetTextMatrix(context, .{
        .a = 1.0, .b = 0.0,
        .c = 0.0, .d = -1.0,
        .tx = 0.0, .ty = 0.0,
    });

    // Position glyph - negate the bounding box origin to position glyph at (0,0) in buffer
    const text_pos_x = -rect.origin.x;
    const text_pos_y = @as(f64, @floatFromInt(height)) - rect.origin.y;

    // Set the font on the context
    const cg_font = ct.CTFontCopyGraphicsFont(self.ct_font, null) orelse return error.FontConversionFailed;
    defer ct.releaseCF(cg_font);
    ct.CGContextSetFont(context, cg_font);
    ct.CGContextSetFontSize(context, @floatCast(self.size));
    ct.CGContextSetTextDrawingMode(context, .fill);

    // Draw using CGContextShowGlyphsAtPoint
    ct.CGContextShowGlyphsAtPoint(context, text_pos_x, text_pos_y, &glyphs, 1);

    // Flush/synchronize to ensure drawing is complete
    ct.CGContextSynchronize(context);
}
