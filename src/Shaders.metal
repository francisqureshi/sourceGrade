#include <metal_stdlib>
using namespace metal;

// Vertex data structure
struct VertexIn {
    float2 position;
    float4 color;
};

// Data passed from vertex shader to fragment shader
struct VertexOut {
    float4 position [[position]];
    float4 color;
};

// Vertex shader
vertex VertexOut vertexShader(
    uint vertexID [[vertex_id]],
    device const VertexIn* vertices [[buffer(0)]],
    constant float2& viewportSize [[buffer(1)]])
{
    VertexOut out;

    // Convert position from pixel space to normalized device coordinates
    float2 pixelPosition = vertices[vertexID].position;
    float2 viewportSizeFloat = float2(viewportSize.x, viewportSize.y);

    // Normalize to [-1, 1] range
    out.position = float4(0.0, 0.0, 0.0, 1.0);
    out.position.xy = pixelPosition / (viewportSizeFloat / 2.0);

    // Pass color through to fragment shader
    out.color = vertices[vertexID].color;

    return out;
}

// Fragment shader
fragment float4 fragmentShader(VertexOut in [[stage_in]])
{
    return in.color;
}
