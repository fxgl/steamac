#version 450
// The VS writes vec3 POSITION and float TEXCOORD at location 0; reading only
// POSITION is legal. Its input buffer must still include padding for TEXCOORD.
layout(vertices = 3) out;
layout(location = 0) in vec3 POSITION[];
layout(location = 0) out vec3 pos[];
layout(location = 0, component = 3) out float tc[];

void main()
{
	pos[gl_InvocationID] = POSITION[gl_InvocationID];
	tc[gl_InvocationID] = 0.25;
	if (gl_InvocationID == 0) {
		gl_TessLevelOuter[0] = 1.0;
		gl_TessLevelOuter[1] = 1.0;
		gl_TessLevelOuter[2] = 1.0;
		gl_TessLevelInner[0] = 1.0;
	}
}
