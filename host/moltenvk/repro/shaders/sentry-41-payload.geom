#version 450
layout(points) in;
layout(triangle_strip, max_vertices = 4) out;
layout(location = 0) in vec4 position[];
layout(location = 1) in vec4 color[];
layout(location = 2) in float size[];
layout(location = 1) out vec4 result;
void main()
{
    for (int i = 0; i < 4; i++) {
        gl_Position = position[0] + vec4(vec2((i & 1) * 2 - 1, (i >> 1) * 2 - 1) * size[0], 0.0, 0.0);
        result = color[0];
        EmitVertex();
    }
    EndPrimitive();
}
