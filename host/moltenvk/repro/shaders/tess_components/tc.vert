#version 450
// tess_components.c: dxil-spirv's output signature of Ratchet & Clank: Rift Apart's tessellation vertex shaders
// (steamac #49): POSITION (float3) and TEXCOORD (float) share location 0, written one component at a time.
// Under tessellation the vertex stage captures its outputs to a buffer. SPIRV-Cross 0042 already fixes the
// address space of component stores, but packing these outputs into a 16-byte float4 disagrees with the
// control stage's separate float3 + float members (32 bytes): wrong control points produce an empty draw.
layout(location = 0) out vec3 POSITION;
layout(location = 0, component = 3) out float TEXCOORD;

void main()
{
	// One triangle covering the viewport: (-1,-1), (3,-1), (-1,3).
	POSITION.x = gl_VertexIndex == 1 ? 3.0 : -1.0;
	POSITION.y = gl_VertexIndex == 2 ? 3.0 : -1.0;
	POSITION.z = 0.5;
	TEXCOORD = 0.25;
}
