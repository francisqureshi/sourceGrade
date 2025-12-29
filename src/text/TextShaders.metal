#include <metal_stdlib>
using namespace metal;

struct TextVertex {
    uint2 glyph_pos;      // Position in atlas
    uint2 glyph_size;     // Size in atlas
    int2 bearings;        // Left/top bearings
    float2 screen_pos;    // Screen position (pixels)
    uchar4 color;         // RGBA color
};

struct TextFragmentIn {
    float4 position [[position]];
    float4 color;
    float2 tex_coord;
};

vertex TextFragmentIn textVertexShader(
    uint vid [[vertex_id]],
    device const TextVertex* vertices [[buffer(0)]],
    constant float2& screen_size [[buffer(1)]]
) {
    // For indexed rendering: each glyph has 4 vertices, but they all share the same TextVertex data
    // We read the glyph data based on which glyph this vertex belongs to
    uint glyph_idx = vid / 4;
    TextVertex in = vertices[glyph_idx];

    // Calculate which corner of the quad (indexed triangles)
    // Vertex order per quad: 0=TL, 1=TR, 2=BR, 3=BL
    uint corner_idx = vid % 4;
    float2 corner;
    corner.x = (corner_idx == 1 || corner_idx == 2) ? 1.0 : 0.0;  // Right side: TR(1), BR(2)
    corner.y = (corner_idx == 2 || corner_idx == 3) ? 1.0 : 0.0;  // Bottom: BR(2), BL(3)

    // Calculate glyph quad position
    float2 size = float2(in.glyph_size);
    float2 offset = float2(in.bearings);

    // Build the quad: top-left to bottom-right
    float2 pos = in.screen_pos + offset + size * corner;

    // DEBUG: Force position to be visible
    pos = float2(100, 100) + size * corner;

    // Convert to NDC (-1 to 1)
    float2 ndc = (pos / screen_size) * 2.0 - 1.0;
    ndc.y = -ndc.y;  // Flip Y for Metal coordinate system

    // Calculate texture coordinates in atlas (pixel coordinates for coord::pixel sampler)
    // Need to flip Y because CoreGraphics renders with flipped Y coordinate system
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
    constexpr sampler texSampler(coord::pixel, filter::linear, address::clamp_to_zero);

    // Sample alpha from grayscale atlas
    float alpha = atlas.sample(texSampler, in.tex_coord).r;

    // DEBUG: Show alpha value
    if (alpha > 0.01) {
        return float4(alpha, alpha, alpha, 1.0);  // Show grayscale
    // } else {
    //     return float4(1.0, 0.0, 0.0, 0.3);  // Red tint where alpha is 0
    }

    // Apply alpha to color
    float4 color = in.color;
    color.a *= alpha;

    return color;
}
