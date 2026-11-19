#version 450
// STEAMAC-AV: the real shader's ATTRIBUTE_5 is float2[2], fed by half2 formats.
layout(location=5) in vec2 attributes[2];
layout(location=0) out vec4 result;
void main() {
    result = vec4(attributes[0], attributes[1]);
    gl_Position = vec4(attributes[0] + attributes[1], 0.0, 1.0);
}
