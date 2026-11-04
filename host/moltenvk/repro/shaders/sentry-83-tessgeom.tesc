#version 450
layout(vertices = 3) out;
layout(location = 0) in vec3 position[];
layout(location = 0) out vec3 tessPosition[];
void main()
{
    tessPosition[gl_InvocationID] = position[gl_InvocationID];
    gl_TessLevelOuter[0] = 1.0;
    gl_TessLevelOuter[1] = 1.0;
    gl_TessLevelOuter[2] = 1.0;
    gl_TessLevelInner[0] = 1.0;
}
