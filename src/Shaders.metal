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

float linearize(float v) {
    return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4);
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
// http://www.brucelindbloom.com/Eqn_RGB_XYZ_Matrix.html
constant float3x3 sRGB_XYZ = transpose(float3x3(
  0.4360747, 0.3850649, 0.1430804,
  0.2225045, 0.7168786, 0.0606169,
  0.0139322, 0.0971045, 0.7141733
));

// XYZ to Display P3 conversion matrix
// http://endavid.com/index.php?entry=79
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

// Vertex data structure (updated to use buffer data)
// Packed to match Zig's extern struct layout
struct VertexIn {
    packed_float2 position;
    packed_float4 color;
};

// Data passed from vertex shader to fragment shader
struct VertexOut {
    float4 position [[position]];
    float4 color;
};

// Vertex shader with rotation - reads from vertex buffer
vertex VertexOut vertexShaderBuffered(
    uint vertexID [[vertex_id]],
    device const VertexIn* vertices [[buffer(0)]],
    constant float &rotationAngle [[buffer(1)]],  // Rotation angle in radians
    constant float2 &translation [[buffer(2)]])    // Translation
{
    VertexOut out;

    // Read position and color from the vertex buffer
    float2 position = vertices[vertexID].position;
    out.color = vertices[vertexID].color;  // No gamma conversion

    // Apply 2D rotation matrix
    float cosAngle = cos(rotationAngle);
    float sinAngle = sin(rotationAngle);

    float2 rotatedPos;
    rotatedPos.x = position.x * cosAngle - position.y * sinAngle;
    rotatedPos.y = position.x * sinAngle + position.y * cosAngle;

    rotatedPos += translation;

    out.position = float4(rotatedPos, 0.0, 1.0);

    return out;
}

// Fragment shader
fragment float4 fragmentShader(VertexOut in [[stage_in]])
{
    // Native blending: no gamma conversion
    return in.color;
}

// ============================================================================
// IMGUI Shaders (for immediate-mode UI rendering)
// ============================================================================

// IMGUI Uniforms for configuration
struct ImGuiUniforms {
    float2 screen_size;      // Screen dimensions
    bool use_display_p3;     // Convert sRGB to Display P3
};

// IMGUI Vertex data structure (matches ImVertex in imgui.zig)
struct ImGuiVertexIn {
    packed_float2 position;  // Screen space position
    packed_float2 uv;        // Texture coordinates
    uint color;              // Packed RGBA8 color
};

// IMGUI interpolated data
struct ImGuiVertexOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
    bool use_display_p3 [[flat]];
};

// IMGUI Vertex shader - converts screen coordinates to clip space
vertex ImGuiVertexOut imguiVertexShader(
    uint vertexID [[vertex_id]],
    device const ImGuiVertexIn* vertices [[buffer(0)]],
    constant ImGuiUniforms &uniforms [[buffer(1)]])
{
    ImGuiVertexOut out;

    // Read from vertex buffer
    float2 pos = vertices[vertexID].position;
    out.uv = vertices[vertexID].uv;
    out.use_display_p3 = uniforms.use_display_p3;

    // Unpack RGBA8 color to float4 (sRGB gamma-encoded input)
    uint packed = vertices[vertexID].color;
    out.color = float4(
        float(packed & 0xFF) / 255.0,          // R
        float((packed >> 8) & 0xFF) / 255.0,   // G
        float((packed >> 16) & 0xFF) / 255.0,  // B
        float((packed >> 24) & 0xFF) / 255.0   // A
    );

    // Convert screen coordinates [0, screen_size] to clip space [-1, 1]
    // Note: Y is flipped (Metal's origin is top-left, clip space origin is center)
    float2 clipPos;
    clipPos.x = (pos.x / uniforms.screen_size.x) * 2.0 - 1.0;
    clipPos.y = 1.0 - (pos.y / uniforms.screen_size.y) * 2.0;

    out.position = float4(clipPos, 0.0, 1.0);

    return out;
}

// IMGUI Fragment shader - supports both shapes and text
fragment float4 imguiFragmentShader(
    ImGuiVertexOut in [[stage_in]],
    texture2d<float> atlas [[texture(0)]])
{
    float4 color = in.color;

    // If UV is non-zero, sample font atlas (text rendering)
    if (in.uv.x > 0.0 || in.uv.y > 0.0) {
        constexpr sampler textureSampler(filter::linear);
        float alpha = atlas.sample(textureSampler, in.uv).r;  // Grayscale atlas
        color.a *= alpha;  // Modulate alpha channel only
    }

    // GAMMA-CORRECT BLENDING: Linearize first, then premultiply
    // This is critical for proper antialiased text rendering
    color.rgb = float3(
        linearize(color.r),
        linearize(color.g),
        linearize(color.b)
    );

    // Premultiply alpha in LINEAR space (gamma-correct)
    color.rgb *= color.a;

    // If Display P3 is enabled, convert color space
    if (in.use_display_p3) {
        // Convert from linear sRGB to linear Display P3
        color.rgb = srgb_to_display_p3(color.rgb);
    }

    return color;
}

// ============================================================================
// Video Texture Shaders (for displaying video frames)
// ============================================================================

struct VideoUniforms {
    float2 video_size;    // Video dimensions (width, height)
    float2 viewport_size; // Window/viewport dimensions
};

struct VideoVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Vertex shader with letterboxing to maintain aspect ratio
vertex VideoVertexOut videoVertexShader(
    uint vertexID [[vertex_id]],
    constant VideoUniforms &uniforms [[buffer(0)]])
{
    VideoVertexOut out;

    // Calculate aspect ratios
    float video_aspect = uniforms.video_size.x / uniforms.video_size.y;
    float viewport_aspect = uniforms.viewport_size.x / uniforms.viewport_size.y;

    // Calculate scale to fit video in viewport (letterbox/pillarbox)
    float2 scale;
    if (video_aspect > viewport_aspect) {
        // Video is wider - letterbox top/bottom
        scale.x = 1.0;
        scale.y = viewport_aspect / video_aspect;
    } else {
        // Video is taller - pillarbox left/right
        scale.x = video_aspect / viewport_aspect;
        scale.y = 1.0;
    }

    // Full-screen quad coordinates, scaled for aspect ratio
    float2 positions[4] = {
        float2(-scale.x, -scale.y),  // bottom-left
        float2( scale.x, -scale.y),  // bottom-right
        float2(-scale.x,  scale.y),  // top-left
        float2( scale.x,  scale.y)   // top-right
    };

    float2 texCoords[4] = {
        float2(0.0, 1.0),  // bottom-left (flip Y for video)
        float2(1.0, 1.0),  // bottom-right
        float2(0.0, 0.0),  // top-left
        float2(1.0, 0.0)   // top-right
    };

    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];

    return out;
}

// Rec.709 Y'CbCr to RGB conversion matrix (video range)
constant float3x3 ycbcr_to_rgb_rec709 = float3x3(
    float3(1.164384,  1.164384,  1.164384),
    float3(0.0,      -0.213249,  2.112402),
    float3(1.792741, -0.532909,  0.0)
);

// Sample video texture - YCbCr 16-bit tri-planar (ProRes 4444)
// Textures are 16-bit, automatically promoted to 32-bit float by Metal
fragment float4 videoFragmentShader(
    VideoVertexOut in [[stage_in]],
    texture2d<float> yTexture [[texture(0)]],      // Y (Luma) plane - R16Unorm
    texture2d<float> cbcrTexture [[texture(1)]],   // CbCr (Chroma) plane - RG16Unorm
    texture2d<float> alphaTexture [[texture(2)]])  // Alpha plane - R16Unorm
{
    constexpr sampler textureSampler(filter::linear);

    // Sample all three planes (16-bit textures → 32-bit float automatically)
    // float y = yTexture.sample(textureSampler, in.texCoord).r;
    float2 cbcr = cbcrTexture.sample(textureSampler, in.texCoord).rg;
    float alpha = alphaTexture.sample(textureSampler, in.texCoord).r;

    // DEBUG: Show raw Y channel to check if texture sampling is correct
    float y = 1.0 - yTexture.sample(textureSampler, in.texCoord).r;
    return float4(y, y, y, 1.0);

    // // TRY: Just use the values directly (full range)
    // // Center CbCr around 0
    // float cb = cbcr.g - 0.5;
    // float cr = cbcr.r - 0.5;

    // // Simple Rec.709 full-range conversion
    // float r = y + 1.5748 * cr;
    // float g = y + 0.1873 * cb + 0.4681 * cr;
    // float b = y + 1.8556 * cb;

    // // Return RGB directly without linearization
    // // (VideoToolbox may already provide linear YCbCr data)
    // return float4(saturate(r), saturate(g), saturate(b), alpha);
}
