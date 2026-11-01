#version 450
layout(vertices = 3) out;
layout(location = 0) in vec3 POSITION[];
layout(location = 0, component = 3) in float TEXCOORD[];
layout(location = 0) out vec3 pos[];
layout(location = 0, component = 3) out float tc[];

void main()
{
	pos[gl_InvocationID] = POSITION[gl_InvocationID];
	tc[gl_InvocationID] = TEXCOORD[gl_InvocationID];
	if (gl_InvocationID == 0) {
		gl_TessLevelOuter[0] = 1.0;
		gl_TessLevelOuter[1] = 1.0;
		gl_TessLevelOuter[2] = 1.0;
		gl_TessLevelInner[0] = 1.0;
	}
}
