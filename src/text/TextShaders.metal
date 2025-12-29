#include <metal_stdlib>
using namespace metal;

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
};

vertex TextFragmentIn textVertexShader(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    constant TextVertex* vertices [[buffer(0)]],
    constant float2& screen_size [[buffer(1)]]
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
    float2 base_pos = in.screen_pos;

    float2 pos = base_pos + glyph_size * corner;

    // Convert to NDC (-1 to 1)
    float2 ndc = (pos / screen_size) * 2.0 - 1.0;
    ndc.y = -ndc.y;  // Flip Y for Metal coordinate system

    // Calculate texture coordinates
    float2 tex_corner = corner;
    tex_corner.y = 1.0 - tex_corner.y;  // Flip Y for texture sampling
    float2 tex_coord = float2(in.glyph_pos) + float2(in.glyph_size) * tex_corner;

    TextFragmentIn out;
    out.position = float4(ndc, 0.0, 1.0);
    out.color = float4(in.color) / 255.0;
    out.tex_coord = tex_coord;

    return out;
}

fragment float4 textFragmentShader(
    TextFragmentIn in [[stage_in]],
    texture2d<float> atlas [[texture(0)]]
) {
    constexpr sampler smp(coord::pixel, address::clamp_to_edge, filter::linear);

    // Sample the atlas (grayscale R8)
    float alpha = atlas.sample(smp, in.tex_coord).r;

    // DEBUG: Show texture coordinates as color to verify they're correct
    // Expected: very dark (tex_coord around 1-20 for small glyphs at atlas origin)
    if (alpha > 0.01) {
        return float4(1.0, 1.0, 1.0, 1.0); // White if we got glyph data
    }

    // Show tex_coord values as colors (divide by 50 to see range 0-50)
    return float4(in.tex_coord.x / 50.0, in.tex_coord.y / 50.0, 0.0, 1.0);
}
