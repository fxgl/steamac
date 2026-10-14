#version 460
// A plain vertex shader for the fragment-stage subgroup control: no subgroup ops, so the control
// pipeline can be created even on a driver whose vertex-stage subgroup support is missing.
void main()
{
	// A fullscreen triangle: (-1,-1), (3,-1), (-1,3) — every pixel of the target is covered.
	vec2 p = vec2(float((gl_VertexIndex << 1) & 2), float(gl_VertexIndex & 2));
	gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
