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
    constant float &rotationAngle [[buffer(1)]])  // Rotation angle in radians
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

    out.position = float4(rotatedPos, 0.0, 1.0);

    return out;
}

// Fragment shader
fragment float4 fragmentShader(VertexOut in [[stage_in]])
{
    return in.color;
}
