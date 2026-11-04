#version 450
layout(location = 0) out vec4 coordinate;
void main()
{
    vec2 xy = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2) * 2.0 - 1.0;
    gl_Position = vec4(xy, 0.0, 1.0);
    coordinate = vec4(xy * 0.25 + 0.5, 0.4, 1.0);
}
