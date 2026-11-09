#version 450
// STEAMAC-A2: native ClipDistance and its fragment-readable user copies must coexist.
#if defined(VERTEX)
out gl_PerVertex { vec4 gl_Position; float gl_ClipDistance[CLIP_COUNT]; };
void main()
{
    const vec2 positions[3] = vec2[3](vec2(-1.0, -1.0), vec2(1.0, -1.0), vec2(0.0, 1.0));
    gl_Position = vec4(positions[gl_VertexIndex % 3], 0.0, 1.0);
    for (int plane = 0; plane < CLIP_COUNT; ++plane)
        gl_ClipDistance[plane] = float(plane + 1) + float(gl_VertexIndex % 3) * 0.125;
}
#elif defined(GEOMETRY)
layout(triangles) in;
layout(triangle_strip, max_vertices = 3) out;
in gl_PerVertex { vec4 gl_Position; float gl_ClipDistance[CLIP_COUNT]; } gl_in[];
out gl_PerVertex { vec4 gl_Position; float gl_ClipDistance[CLIP_COUNT]; };
void emit_clip(int vertex)
{
    gl_Position = gl_in[vertex].gl_Position;
    for (int plane = 0; plane < CLIP_COUNT; ++plane)
        gl_ClipDistance[plane] = gl_in[vertex].gl_ClipDistance[plane];
    EmitVertex();
}
void main()
{
    for (int vertex = 0; vertex < 3; ++vertex)
        emit_clip(vertex);
    EndPrimitive();
}
#elif defined(FRAGMENT)
layout(location = 0) out vec4 color;
#if USER_COPY
in float gl_ClipDistance[CLIP_COUNT];
#endif
void main()
{
#if USER_COPY
    color = vec4(gl_ClipDistance[0], gl_ClipDistance[CLIP_COUNT - 1], 0.0, 1.0);
#else
    color = vec4(1.0);
#endif
}
#endif
