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

    // Calculate bounds like Ghostty (x0, x1, y0, y1)
    var x0: i32 = @intFromFloat(@floor(rect.origin.x));
    var x1: i32 = @intFromFloat(@ceil(rect.origin.x) + @ceil(rect.size.width));
    var y0: i32 = @intFromFloat(@floor(rect.origin.y));
    var y1: i32 = @intFromFloat(@ceil(rect.origin.y) + @ceil(rect.size.height));

    // Expand buffer by 1 pixel on each edge for antialiasing (Ghostty approach)
    // Font smoothing adds up to 1px of blur on each edge
    x0 -= 1;
    x1 += 1;
    y0 -= 1;
    y1 += 1;

    const width: u32 = @intCast(x1 - x0);
    const height: u32 = @intCast(y1 - y0);

    return Glyph{
        .id = glyph_id,
        .width = width,
        .height = height,
        .bearing_x = x0,
        .bearing_y = y0, // Store y0, not y1 (we'll handle this in shader)
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

    // Clear buffer to 0 (alpha=0 background) - MUST do this before creating context
    @memset(buffer, 0);

    // Get bounding rect and calculate x0, y0 like in getGlyphMetrics
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

    // Expand buffer by 1 pixel on each edge for antialiasing (same as getGlyphMetrics)
    const x0: i32 = @as(i32, @intFromFloat(@floor(rect.origin.x))) - 1;
    const y0: i32 = @as(i32, @intFromFloat(@floor(rect.origin.y))) - 1;

    // Create linear grayscale color space (like Ghostty)
    const color_space = ct.CGColorSpaceCreateWithName(ct.kCGColorSpaceLinearGray) orelse
        return error.ColorSpaceCreateFailed;
    defer ct.releaseCF(color_space);

    // Create bitmap context with alpha-only like Ghostty
    // With kCGImageAlphaOnly, buffer contains only alpha values
    const context = ct.CGBitmapContextCreate(
        buffer.ptr,
        width,
        height,
        8, // 8 bits per component
        width, // bytes per row
        color_space,
        ct.kCGImageAlphaOnly,
    ) orelse {
        std.debug.print("Context creation FAILED\n", .{});
        return error.ContextCreateFailed;
    };
    defer ct.releaseCF(context);

    // Clear background with compositing_alpha=0 (doesn't actually write, relies on memset)
    ct.CGContextSetGrayFillColor(context, 1.0, 0.0);
    ct.CGContextFillRect(context, .{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = @floatFromInt(width), .height = @floatFromInt(height) },
    });

    // Enable antialiasing and font smoothing (like Ghostty)
    ct.CGContextSetAllowsAntialiasing(context, true);
    ct.CGContextSetShouldAntialias(context, true);
    ct.CGContextSetAllowsFontSmoothing(context, true);
    ct.CGContextSetShouldSmoothFonts(context, true);
    ct.CGContextSetAllowsFontSubpixelPositioning(context, true);
    ct.CGContextSetShouldSubpixelPositionFonts(context, true);
    ct.CGContextSetAllowsFontSubpixelQuantization(context, true);
    ct.CGContextSetShouldSubpixelQuantizeFonts(context, true);

    // Set fill color for glyph
    // Use slightly less than full opacity to trigger better antialiasing
    // (Ghostty uses thicken_strength/255.0, default 255 = 1.0)
    const strength: f64 = 255.0 / 255.0; // Full strength
    ct.CGContextSetGrayFillColor(context, strength, 1.0);

    // Position glyph in buffer (Ghostty approach: simple negation of origin)
    const positions = [_]ct.CGPoint{.{
        .x = @floatFromInt(-x0),
        .y = @floatFromInt(-y0),
    }};

    // Draw using CTFontDrawGlyphs (higher-level API with better antialiasing)
    ct.CTFontDrawGlyphs(self.ct_font, &glyphs, &positions, 1, context);
}
