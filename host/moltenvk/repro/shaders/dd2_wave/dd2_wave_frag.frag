#version 460
// The fragment-stage control: the same subgroup ops in a stage Metal does support, including the
// '[[thread_index_in_simdgroup]]' attribute KosmicKrisp declares there. This must pass on both
// drivers today — it is what makes the vertex-stage verdict meaningful.
#extension GL_KHR_shader_subgroup_basic : require
#extension GL_KHR_shader_subgroup_ballot : require
#extension GL_KHR_shader_subgroup_arithmetic : require

layout(location = 0) out vec4 c;

layout(set = 0, binding = 1, std430) buffer FragWave {
	uvec4 frag[]; // x lane, y ballot(true) mask, z exclusive scan of 1
} fw;

void main()
{
	vec2 p = gl_FragCoord.xy;
	uint idx = uint(int(p.y) * 64 + int(p.x));
	uvec4 r;
	r.x = gl_SubgroupInvocationID;
	r.y = uint(subgroupBallot(true).x);
	r.z = subgroupExclusiveAdd(1u);
	fw.frag[idx] = r;
	c = vec4(float(r.x) * 0.25, float(r.y) * 0.001, 0.0, 1.0);
}
