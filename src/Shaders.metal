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

// Vertex shader with rotation
vertex VertexOut vertexShader(
    uint vertexID [[vertex_id]],
    device const VertexIn* vertices [[buffer(0)]],
    constant float &rotationAngle [[buffer(1)]])  // Rotation angle in radians
{
    VertexOut out;

    // Define base positions for the triangle
    float2 position;
    if (vertexID == 0) {
        position = float2(0.0, 0.5);     // Top
        out.color = float4(0.0, 1.0, 0.0, 1.0);  // Green
    } else if (vertexID == 1) {
        position = float2(-0.5, -0.5);   // Bottom-left
        out.color = float4(0.0, 0.0, 1.0, 1.0);  // Blue
    } else {
        position = float2(0.5, -0.5);    // Bottom-right
        out.color = float4(1.0, 0.0, 0.0, 1.0);  // Red
    }
    
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
