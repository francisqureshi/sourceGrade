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
    device const VertexIn* vertices [[buffer(0)]])
{
    VertexOut out;

    // HARDCODE positions that we know work
    if (vertexID == 0) {
        out.position = float4(0.0, 0.5, 0.0, 1.0);  // Top
        out.color = float4(0.0, 1.0, 0.0, 1.0);      // Green
    } else if (vertexID == 1) {
        out.position = float4(-0.5, -0.5, 0.0, 1.0); // Bottom-left
        out.color = float4(0.0, 0.0, 1.0, 1.0);      // Blue
    } else {
        out.position = float4(0.5, -0.5, 0.0, 1.0);  // Bottom-right
        out.color = float4(1.0, 0.0, 0.0, 1.0);      // Red
    }

    return out;
}

// Fragment shader
fragment float4 fragmentShader(VertexOut in [[stage_in]])
{
    return in.color;
}
