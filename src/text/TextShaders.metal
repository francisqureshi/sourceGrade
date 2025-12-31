#include <metal_stdlib>
using namespace metal;

//-------------------------------------------------------------------
// Color Space Conversion (Linear RGB ↔ sRGB)
//-------------------------------------------------------------------

// Converts a color from sRGB gamma encoding to linear RGB
// NOTE: Alpha is NOT gamma corrected - it stays linear!
float4 linearize(float4 srgb) {
    bool3 cutoff = srgb.rgb <= 0.04045;
    float3 lower = srgb.rgb / 12.92;
    float3 higher = pow((srgb.rgb + 0.055) / 1.055, 2.4);
    float4 result = srgb;
    result.rgb = mix(higher, lower, float3(cutoff));
    return result;  // Alpha unchanged
}

// Converts a color from linear RGB to sRGB gamma encoding
float4 unlinearize(float4 linear) {
    bool3 cutoff = linear.rgb <= 0.0031308;
    float3 lower = linear.rgb * 12.92;
    float3 higher = pow(linear.rgb, 1.0 / 2.4) * 1.055 - 0.055;
    linear.rgb = mix(higher, lower, float3(cutoff));
    return linear;
}

//-------------------------------------------------------------------
// Display P3 Color Space Conversion
//-------------------------------------------------------------------

// D50-adapted sRGB to XYZ conversion matrix
constant float3x3 sRGB_XYZ = transpose(float3x3(
  0.4360747, 0.3850649, 0.1430804,
  0.2225045, 0.7168786, 0.0606169,
  0.0139322, 0.0971045, 0.7141733
));

// XYZ to Display P3 conversion matrix
constant float3x3 XYZ_DP3 = transpose(float3x3(
  2.40414768,-0.99010704,-0.39759019,
 -0.84239098, 1.79905954, 0.01597023,
  0.04838763,-0.09752546, 1.27393636
));

// Composed sRGB to Display P3 conversion matrix
constant float3x3 sRGB_DP3 = XYZ_DP3 * sRGB_XYZ;

// Converts a color in linear sRGB to linear Display P3
float3 srgb_to_display_p3(float3 srgb) {
  return sRGB_DP3 * srgb;
}

// Text rendering uniforms
struct TextUniforms {
    float2 screen_size;      // Screen dimensions
    bool use_display_p3;     // Convert sRGB to Display P3
};

struct TextVertex {
    uint2 glyph_pos;      // Position in atlas (8 bytes, offset 0)
    uint2 glyph_size;     // Size in atlas (8 bytes, offset 8)
    float2 screen_pos;    // Screen position (8 bytes, offset 16) - Zig reordered!
    short2 bearings;      // Left/top bearings (4 bytes, offset 24)
    uchar4 color;         // RGBA color (4 bytes, offset 28)
};

struct TextFragmentIn {
    float4 position [[position]];
    float4 color;
    float2 tex_coord;
    bool use_display_p3 [[flat]];
};

vertex TextFragmentIn textVertexShader(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    constant TextVertex* vertices [[buffer(0)]],
    constant TextUniforms& uniforms [[buffer(1)]]
) {
    // Get the glyph data from instance (1 vertex per glyph)
    TextVertex in = vertices[iid];

    // Calculate corner from vertex ID (0-3 for each instance)
    // 0 = top-right, 1 = bot-right, 2 = bot-left, 3 = top-left
    float2 corner;
    corner.x = (vid == 0 || vid == 1) ? 1.0 : 0.0;
    corner.y = (vid == 0 || vid == 3) ? 0.0 : 1.0;

    // Use actual glyph data
    float2 glyph_size = float2(in.glyph_size);
    float2 base_pos = in.screen_pos;  // baseline position
    float2 bearings = float2(in.bearings);  // x0, y0

    // Position glyph at baseline
    // bearings.y is y0 (bottom of glyph), we need y1 (top) for screen positioning
    // In screen coords (Y-down): top_left = baseline - y1 = baseline - (y0 + height)
    float2 offset;
    offset.x = bearings.x;  // x0: left bearing
    offset.y = -(bearings.y + glyph_size.y);  // -(y0 + height) = -y1

    float2 pos = base_pos + offset + glyph_size * corner;

    // Convert to NDC (-1 to 1)
    float2 ndc = (pos / uniforms.screen_size) * 2.0 - 1.0;
    ndc.y = -ndc.y;  // Flip Y for Metal coordinate system

    // Calculate texture coordinates
    float2 tex_corner = corner;
    tex_corner.y = 1.0 - tex_corner.y;  // Flip Y for texture sampling
    float2 tex_coord = float2(in.glyph_pos) + float2(in.glyph_size) * tex_corner;

    TextFragmentIn out;
    out.position = float4(ndc, 0.0, 1.0);

    // Convert color from 0-255 to 0-1 (sRGB gamma-encoded input)
    out.color = float4(in.color) / 255.0;

    out.tex_coord = tex_coord;
    out.use_display_p3 = uniforms.use_display_p3;

    return out;
}

fragment float4 textFragmentShader(
    TextFragmentIn in [[stage_in]],
    texture2d<float> atlas [[texture(0)]]
) {
    constexpr sampler textureSampler(
        coord::pixel,
        address::clamp_to_edge,
        filter::linear
    );

    // Sample the atlas (grayscale R8)
    float alpha = atlas.sample(textureSampler, in.tex_coord).r;

    float4 color = in.color;

    // If Display P3 is enabled, convert color space
    if (in.use_display_p3) {
        // Linearize sRGB input
        color = linearize(color);

        // Convert from linear sRGB to linear Display P3
        color.rgb = srgb_to_display_p3(color.rgb);
    }

    // Multiply by atlas alpha (coverage), then premultiply
    color *= alpha;

    return color;
}
