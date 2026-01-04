//! CoreText and CoreGraphics C API bindings for text rendering
//! Minimal subset needed for glyph rasterization

const std = @import("std");

// CoreFoundation types
pub const CFStringRef = *opaque {};
pub const CFDataRef = *opaque {};
pub const CFDictionaryRef = *opaque {};
pub const CFAllocatorRef = ?*opaque {};

// CoreText types
pub const CTFontRef = *opaque {};
pub const CTFontDescriptorRef = *opaque {};

// CoreGraphics types
pub const CGContextRef = *opaque {};
pub const CGColorSpaceRef = *opaque {};
pub const CGGlyph = u16;
pub const CGFloat = f64;

pub const CGPoint = extern struct {
    x: CGFloat,
    y: CGFloat,
};

pub const CGSize = extern struct {
    width: CGFloat,
    height: CGFloat,
};

pub const CGRect = extern struct {
    origin: CGPoint,
    size: CGSize,
};

pub const CGAffineTransform = extern struct {
    a: CGFloat,
    b: CGFloat,
    c: CGFloat,
    d: CGFloat,
    tx: CGFloat,
    ty: CGFloat,
};

// CoreFoundation constants
pub const kCFStringEncodingUTF8: u32 = 0x08000100;

// CoreGraphics constants
pub const kCGImageAlphaNone: u32 = 0;
pub const kCGImageAlphaPremultipliedFirst: u32 = 2;
pub const kCGImageAlphaOnly: u32 = 7;
pub const kCGBitmapByteOrderDefault: u32 = 0;
pub const kCGRenderingIntentDefault: u32 = 0;

// CoreGraphics color space names
pub extern var kCGColorSpaceLinearGray: *const anyopaque;

pub extern "c" fn CGColorSpaceCreateWithName(name: *const anyopaque) ?CGColorSpaceRef;

// Font orientation
pub const kCTFontOrientationDefault: u32 = 0;
pub const kCTFontOrientationHorizontal: u32 = 1;
pub const kCTFontOrientationVertical: u32 = 2;

// CoreFoundation functions
pub extern "c" fn CFStringCreateWithCString(
    alloc: CFAllocatorRef,
    cStr: [*:0]const u8,
    encoding: u32,
) ?CFStringRef;

pub extern "c" fn CFRelease(cf: *anyopaque) void;

// CoreText font functions
pub extern "c" fn CTFontCreateWithName(
    name: CFStringRef,
    size: CGFloat,
    matrix: ?*const CGAffineTransform,
) ?CTFontRef;

pub extern "c" fn CTFontGetGlyphsForCharacters(
    font: CTFontRef,
    characters: [*]const u16,
    glyphs: [*]CGGlyph,
    count: i64,
) bool;

pub extern "c" fn CTFontGetAdvancesForGlyphs(
    font: CTFontRef,
    orientation: u32,
    glyphs: [*]const CGGlyph,
    advances: [*]CGSize,
    count: i64,
) f64;

pub extern "c" fn CTFontGetBoundingRectsForGlyphs(
    font: CTFontRef,
    orientation: u32,
    glyphs: [*]const CGGlyph,
    boundingRects: [*]CGRect,
    count: i64,
) CGRect;

pub extern "c" fn CTFontDrawGlyphs(
    font: CTFontRef,
    glyphs: [*]const CGGlyph,
    positions: [*]const CGPoint,
    count: usize,
    context: CGContextRef,
) void;

// CoreGraphics bitmap context functions
pub extern "c" fn CGBitmapContextCreate(
    data: ?*anyopaque,
    width: usize,
    height: usize,
    bitsPerComponent: usize,
    bytesPerRow: usize,
    space: ?CGColorSpaceRef,
    bitmapInfo: u32,
) ?CGContextRef;

pub extern "c" fn CGColorSpaceCreateDeviceGray() ?CGColorSpaceRef;
pub extern "c" fn CGColorSpaceCreateDeviceRGB() ?CGColorSpaceRef;

pub extern "c" fn CGContextClearRect(context: CGContextRef, rect: CGRect) void;
pub extern "c" fn CGContextFillRect(context: CGContextRef, rect: CGRect) void;
pub extern "c" fn CGContextSetAllowsAntialiasing(context: CGContextRef, allows: bool) void;
pub extern "c" fn CGContextSetShouldAntialias(context: CGContextRef, should: bool) void;
pub extern "c" fn CGContextSetAllowsFontSmoothing(context: CGContextRef, allows: bool) void;
pub extern "c" fn CGContextSetShouldSmoothFonts(context: CGContextRef, should: bool) void;
pub extern "c" fn CGContextSetAllowsFontSubpixelPositioning(context: CGContextRef, allows: bool) void;
pub extern "c" fn CGContextSetShouldSubpixelPositionFonts(context: CGContextRef, should: bool) void;
pub extern "c" fn CGContextSetAllowsFontSubpixelQuantization(context: CGContextRef, allows: bool) void;
pub extern "c" fn CGContextSetShouldSubpixelQuantizeFonts(context: CGContextRef, should: bool) void;
pub extern "c" fn CGContextSetGrayFillColor(context: CGContextRef, gray: CGFloat, alpha: CGFloat) void;
pub extern "c" fn CGContextSetRGBFillColor(context: CGContextRef, red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) void;
pub extern "c" fn CGContextSetTextMatrix(context: CGContextRef, transform: CGAffineTransform) void;
pub extern "c" fn CGContextSetTextPosition(context: CGContextRef, x: CGFloat, y: CGFloat) void;
pub extern "c" fn CGContextShowGlyphsAtPoint(
    context: CGContextRef,
    x: CGFloat,
    y: CGFloat,
    glyphs: [*]const CGGlyph,
    count: usize,
) void;
pub const CGFontRef = *opaque {};
pub extern "c" fn CTFontCopyGraphicsFont(font: CTFontRef, attributes: ?*anyopaque) ?CGFontRef;
pub extern "c" fn CGContextSetFont(context: CGContextRef, font: CGFontRef) void;
pub extern "c" fn CGContextSetFontSize(context: CGContextRef, size: CGFloat) void;
pub extern "c" fn CGContextFlush(context: CGContextRef) void;
pub extern "c" fn CGContextSynchronize(context: CGContextRef) void;

// Text drawing mode
pub const CGTextDrawingMode = enum(c_int) {
    fill = 0,
    stroke = 1,
    fill_stroke = 2,
    invisible = 3,
    fill_clip = 4,
    stroke_clip = 5,
    fill_stroke_clip = 6,
    clip = 7,
};
pub extern "c" fn CGContextSetTextDrawingMode(context: CGContextRef, mode: CGTextDrawingMode) void;

// Helper functions
pub fn createCFString(str: [:0]const u8) ?CFStringRef {
    return CFStringCreateWithCString(null, str.ptr, kCFStringEncodingUTF8);
}

pub fn releaseCF(obj: anytype) void {
    const ptr: *anyopaque = @ptrCast(obj);
    CFRelease(ptr);
}
