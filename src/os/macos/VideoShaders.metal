#include <metal_stdlib>
using namespace metal;

// ============================================================================
// Video Texture Shaders (for displaying decoded video frames)
// Supports BGRA8 and RGBA16Float from VideoToolbox
// Now with viewer viewport support (pan, zoom, bounded rendering)
// ============================================================================

struct VideoUniforms {
    float2 video_size;      // Video dimensions (width, height)
    float2 viewport_size;   // Full window dimensions
    float4 viewer_rect;     // Viewer bounds: x, y, width, height (in screen points)
    float  zoom;            // Zoom level (1.0 = fit, 2.0 = 200%)
    float2 pan_offset;      // Pan offset in normalized coords (-1 to 1)
};

struct VideoVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Vertex shader - renders video into viewer rect with letterboxing, zoom, and pan
vertex VideoVertexOut videoVertexShader(
    uint vertexID [[vertex_id]],
    constant VideoUniforms &uniforms [[buffer(0)]])
{
    VideoVertexOut out;

    // Calculate aspect ratios
    float video_aspect = uniforms.video_size.x / uniforms.video_size.y;
    float viewer_aspect = uniforms.viewer_rect.z / uniforms.viewer_rect.w;  // width / height

    // Calculate scale to fit video in viewer rect (letterbox/pillarbox)
    float2 scale;
    if (video_aspect > viewer_aspect) {
        // Video is wider - letterbox top/bottom
        scale.x = 1.0;
        scale.y = viewer_aspect / video_aspect;
    } else {
        // Video is taller - pillarbox left/right
        scale.x = video_aspect / viewer_aspect;
        scale.y = 1.0;
    }

    // Apply zoom (1.0 = fit, 2.0 = 200% zoom)
    scale *= uniforms.zoom;

    // Quad positions in normalized space (-1 to 1)
    float2 positions[4] = {
        float2(-scale.x, -scale.y),  // bottom-left
        float2( scale.x, -scale.y),  // bottom-right
        float2(-scale.x,  scale.y),  // top-left
        float2( scale.x,  scale.y)   // top-right
    };

    // Convert viewer rect from screen points to clip space (-1 to 1)
    float2 viewer_center = uniforms.viewer_rect.xy + uniforms.viewer_rect.zw * 0.5;
    float2 viewer_half_size = uniforms.viewer_rect.zw * 0.5;

    // Map viewer center to clip space
    float2 clip_center = (viewer_center / uniforms.viewport_size) * 2.0 - 1.0;
    clip_center.y = -clip_center.y;  // Flip Y for Metal coordinate system

    // Map viewer size to clip space
    float2 clip_half_size = (viewer_half_size / uniforms.viewport_size) * 2.0;

    // Scale quad to viewer rect and position in clip space
    float2 scaled_pos = positions[vertexID] * clip_half_size + clip_center;

    // Texture coordinates (flipped Y for video)
    float2 texCoords[4] = {
        float2(0.0, 1.0),  // bottom-left
        float2(1.0, 1.0),  // bottom-right
        float2(0.0, 0.0),  // top-left
        float2(1.0, 0.0)   // top-right
    };

    // Apply pan offset (shifts texture coordinates)
    float2 tex_coord = texCoords[vertexID];
    tex_coord.x += uniforms.pan_offset.x;
    tex_coord.y += uniforms.pan_offset.y;

    out.position = float4(scaled_pos, 0.0, 1.0);
    out.texCoord = tex_coord;

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
