#version 450
layout(triangles, equal_spacing, ccw) in;
layout(location = 0) in vec3 pos[];
layout(location = 0, component = 3) in float tc[];
layout(location = 0) out float v_tc;

void main()
{
	vec3 p = gl_TessCoord.x * pos[0] + gl_TessCoord.y * pos[1] + gl_TessCoord.z * pos[2];
	gl_Position = vec4(p, 1.0);
	v_tc = gl_TessCoord.x * tc[0] + gl_TessCoord.y * tc[1] + gl_TessCoord.z * tc[2];
}
