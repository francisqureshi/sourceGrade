#include <metal_stdlib>
using namespace metal;

// ============================================================================
// Video Texture Shaders (for displaying decoded video frames)
// Supports BGRA8 and RGBA16Float from VideoToolbox
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

// Fragment shader - simple passthrough (VideoToolbox handles color conversion)
fragment float4 videoFragmentShader(
    VideoVertexOut in [[stage_in]],
    texture2d<float> videoTexture [[texture(0)]])
{
    constexpr sampler texSampler(filter::linear, address::clamp_to_edge);
    return videoTexture.sample(texSampler, in.texCoord);
}
