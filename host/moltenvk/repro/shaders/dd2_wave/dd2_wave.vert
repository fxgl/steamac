#version 460
// Wave ops in the vertex stage (Dragon's Dogma 2): the lane id, a ballot, an exclusive scan and
// a broadcast-first. KosmicKrisp emits gl_SubGroupInvocationID as
// 'uint gl_SubGroupInvocation [[thread_index_in_simdgroup]]', which Metal rejects in a vertex
// function ("invalid 'thread_index_in_simdgroup' attribute for input declaration"), so the
// pipeline does not compile. wave_vertex.c checks the values, not just that it compiles:
//
//	lane must be an active bit of ballot(true), and the exclusive scan of 1 over the active lanes
//	must be the number of lanes below 'lane' in that mask — the property a lane-id recovery in a
//	vertex function has to reproduce (a ballot and a scan are Metal's only lane-id sources there).
//
// subgroupBroadcastFirst(gl_VertexID) names the vertex each SIMD group started at, which lets the
// host group records by SIMD group without assuming how vertices map to lanes.
#extension GL_KHR_shader_subgroup_basic : require
#extension GL_KHR_shader_subgroup_ballot : require
#extension GL_KHR_shader_subgroup_arithmetic : require
#extension GL_KHR_shader_subgroup_shuffle : require

layout(location = 0) out vec4 color;

layout(set = 0, binding = 0, std430) buffer Wave {
	uvec4 vert[]; // x lane, y ballot(true) mask, z exclusive scan of 1, w first vertex of the group
} wave;

void main()
{
	uvec4 r;
	r.x = gl_SubgroupInvocationID;
	r.y = uint(subgroupBallot(true).x);
	r.z = subgroupExclusiveAdd(1u);
	r.w = subgroupBroadcastFirst(uint(gl_VertexIndex));
	wave.vert[gl_VertexIndex] = r;

	color = vec4(float(r.x) * 0.03125, float(r.z) * 0.03125, 0.0, 1.0);
	// A fan of small triangles so the draw is a real render pass, not a rasterizer-discarded one.
	float t = float(gl_VertexIndex) * 0.1;
	gl_Position = vec4(0.4 * cos(t), 0.4 * sin(t), 0.0, 1.0);
}
