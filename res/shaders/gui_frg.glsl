#version 450

layout (location = 0) in vec2 inTextCoords;
layout (location = 1) in vec4 inColor;

layout (binding = 0) uniform sampler2D fontsSampler;

layout (location = 0) out vec4 outFragColor;

void main()
{
    // r8_unorm atlas: red channel is coverage/intensity, used as alpha mask.
    // For solid rects UV=(0,0) white pixel: alpha=1.0, color passes through.
    // For glyphs: alpha = glyph coverage.
    float alpha = texture(fontsSampler, inTextCoords).r;
    outFragColor = vec4(inColor.rgb, inColor.a * alpha);
}
