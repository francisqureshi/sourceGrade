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

    // Use position directly from vertex buffer
    out.position = float4(vertices[vertexID].position, 0.0, 1.0);
    
    // Debug: different color for each vertex based on ID
    if (vertexID == 0) {
        out.color = float4(1.0, 0.0, 0.0, 1.0); // Red
    } else if (vertexID == 1) {
        out.color = float4(0.0, 1.0, 0.0, 1.0); // Green
    } else {
        out.color = float4(0.0, 0.0, 1.0, 1.0); // Blue
    }

    return out;
}

// Fragment shader
fragment float4 fragmentShader(VertexOut in [[stage_in]])
{
    return in.color;
}
