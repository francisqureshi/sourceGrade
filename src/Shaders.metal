#include <metal_stdlib>
using namespace metal;

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
    out.color = vertices[vertexID].color;

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
    return in.color;
}

// ============================================================================
// IMGUI Shaders (for immediate-mode UI rendering)
// ============================================================================

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
};

// IMGUI Vertex shader - converts screen coordinates to clip space
vertex ImGuiVertexOut imguiVertexShader(
    uint vertexID [[vertex_id]],
    device const ImGuiVertexIn* vertices [[buffer(0)]],
    constant float2 &screenSize [[buffer(1)]])  // (width, height)
{
    ImGuiVertexOut out;

    // Read from vertex buffer
    float2 pos = vertices[vertexID].position;
    out.uv = vertices[vertexID].uv;

    // Unpack RGBA8 color to float4
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
    clipPos.x = (pos.x / screenSize.x) * 2.0 - 1.0;
    clipPos.y = 1.0 - (pos.y / screenSize.y) * 2.0;

    out.position = float4(clipPos, 0.0, 1.0);

    return out;
}

// IMGUI Fragment shader - simple textured + colored output
fragment float4 imguiFragmentShader(ImGuiVertexOut in [[stage_in]])
{
    // For now, just return vertex color (texture support for font atlas later)
    // When implementing text, we'll add texture sampling as a parameter:
    // texture2d<float> tex [[texture(0)]]
    // float4 texColor = tex.sample(sampler(filter::linear), in.uv);
    // return in.color * texColor;

    return in.color;
}

// ============================================================================
// Video Texture Shaders (for displaying video frames)
// ============================================================================

struct VideoVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Simple vertex shader for full-screen quad
vertex VideoVertexOut videoVertexShader(uint vertexID [[vertex_id]])
{
    VideoVertexOut out;

    // Full-screen quad coordinates
    // vertexID 0,1,2,3 creates two triangles covering the screen
    float2 positions[4] = {
        float2(-1.0, -1.0),  // bottom-left
        float2( 1.0, -1.0),  // bottom-right
        float2(-1.0,  1.0),  // top-left
        float2( 1.0,  1.0)   // top-right
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

// Sample video texture
fragment float4 videoFragmentShader(
    VideoVertexOut in [[stage_in]],
    texture2d<float> videoTexture [[texture(0)]])
{
    constexpr sampler textureSampler(filter::linear);
    return videoTexture.sample(textureSampler, in.texCoord);
}
