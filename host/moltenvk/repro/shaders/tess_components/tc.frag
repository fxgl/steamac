#version 450
layout(location = 0) in float v_tc;
layout(location = 0) out vec4 color;

void main()
{
	color = vec4(v_tc, 0.5, gl_FragCoord.z, 1.0);
}
