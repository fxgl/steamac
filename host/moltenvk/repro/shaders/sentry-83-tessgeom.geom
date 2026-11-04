#version 450
layout(triangles) in;
layout(triangle_strip, max_vertices = 3) out;
layout(location = 0) in vec3 geometryPosition[];
void main()
{
    for (int i = 0; i < 3; i++) {
        gl_Position = vec4(geometryPosition[i], 1.0);
        gl_Layer = 0;
        EmitVertex();
    }
    EndPrimitive();
}
