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
    const x0: i32 = @intFromFloat(@floor(rect.origin.x));
    const x1: i32 = @intFromFloat(@ceil(rect.origin.x) + @ceil(rect.size.width));
    const y0: i32 = @intFromFloat(@floor(rect.origin.y));
    const y1: i32 = @intFromFloat(@ceil(rect.origin.y) + @ceil(rect.size.height));

    const width: u32 = @intCast(x1 - x0);
    const height: u32 = @intCast(y1 - y0);

    return Glyph{
        .id = glyph_id,
        .width = width,
        .height = height,
        .bearing_x = x0,
        .bearing_y = y0,  // Store y0, not y1 (we'll handle this in shader)
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

    const x0: i32 = @intFromFloat(@floor(rect.origin.x));
    const y0: i32 = @intFromFloat(@floor(rect.origin.y));

    // Create linear grayscale color space (like Ghostty)
    const color_space = ct.CGColorSpaceCreateWithName(ct.kCGColorSpaceLinearGray) orelse
        return error.ColorSpaceCreateFailed;
    defer ct.releaseCF(color_space);

    // Create bitmap context with alpha-only like Ghostty
    // With kCGImageAlphaOnly, buffer contains only alpha values
    std.debug.print("Creating context: {}x{}, bytes_per_row={}, buffer.len={}\n", .{ width, height, width, buffer.len });
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
    std.debug.print("Context created successfully\n", .{});

    // Clear background with compositing_alpha=0 (doesn't actually write, relies on memset)
    ct.CGContextSetGrayFillColor(context, 1.0, 0.0);
    ct.CGContextFillRect(context, .{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = @floatFromInt(width), .height = @floatFromInt(height) },
    });

    // Set fill for glyph: gray value is the alpha to write, compositing alpha=1
    // For Ghostty, they use strength/255.0 for the gray, we'll use 1.0 (full alpha)
    ct.CGContextSetGrayFillColor(context, 1.0, 1.0);

    // Enable antialiasing and font smoothing (like Ghostty)
    ct.CGContextSetAllowsAntialiasing(context, true);
    ct.CGContextSetShouldAntialias(context, true);
    ct.CGContextSetAllowsFontSmoothing(context, true);
    ct.CGContextSetShouldSmoothFonts(context, false);  // No thickening
    ct.CGContextSetAllowsFontSubpixelPositioning(context, true);
    ct.CGContextSetShouldSubpixelPositionFonts(context, true);
    ct.CGContextSetAllowsFontSubpixelQuantization(context, true);
    ct.CGContextSetShouldSubpixelQuantizeFonts(context, true);

    // Set text matrix (flip Y coordinate)
    ct.CGContextSetTextMatrix(context, .{
        .a = 1.0, .b = 0.0,
        .c = 0.0, .d = -1.0,
        .tx = 0.0, .ty = 0.0,
    });

    // Position glyph in buffer
    // We want the glyph's top edge (y1) at buffer top (y=0)
    // and bottom edge (y0) at buffer bottom (y=height)
    // With text matrix d=-1 (Y flip), if we draw at (x, y):
    //   the baseline ends up at (x, flipped_y)
    // For the glyph to fill the buffer correctly:
    //   baseline should be at: buffer_height + y0 (since y0 is negative)
    const text_pos_x: f64 = @floatFromInt(-x0);
    const text_pos_y: f64 = @floatFromInt(@as(i32, @intCast(height)) + y0);

    // Set the font on the context
    const cg_font = ct.CTFontCopyGraphicsFont(self.ct_font, null) orelse return error.FontConversionFailed;
    defer ct.releaseCF(cg_font);
    ct.CGContextSetFont(context, cg_font);
    ct.CGContextSetFontSize(context, @floatCast(self.size));
    ct.CGContextSetTextDrawingMode(context, .fill);

    // Draw using CGContextShowGlyphsAtPoint
    std.debug.print("Drawing glyph {} at pos ({d:.1}, {d:.1})\n", .{ glyphs[0], text_pos_x, text_pos_y });
    ct.CGContextShowGlyphsAtPoint(context, text_pos_x, text_pos_y, &glyphs, 1);

    // Flush/synchronize to ensure drawing is complete
    ct.CGContextSynchronize(context);

    // DEBUG: Check if anything was written
    var has_pixels = false;
    for (buffer) |px| {
        if (px > 0) {
            has_pixels = true;
            break;
        }
    }
    std.debug.print("After drawing: buffer has pixels = {}\n", .{has_pixels});
}
