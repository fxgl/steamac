#version 450
#if WIDTH == 3
#define VALUE vec3
#else
#define VALUE vec4
#endif

#if MODE == 1
out Block {
    layout(location = 0) VALUE linked;
    layout(location = 2, component = 0) vec2 low;
    layout(location = 2, component = 2) vec2 high;
} data;
#define linked data.linked
#define low data.low
#define high data.high
#else
layout(location = 0) out VALUE linked;
#if MODE == 2
layout(location = 2, component = 0) out vec3 low;
layout(location = 2, component = 3) out float high;
#else
layout(location = 2, component = 0) out vec2 low;
layout(location = 2, component = 2) out vec2 high;
#endif
#endif

void main()
{
    vec2 positions[3] = vec2[3](vec2(-1, -1), vec2(3, -1), vec2(-1, 3));
    gl_Position = vec4(positions[gl_VertexIndex], 0.5, 1.0);
    linked = VALUE(vec4(2, 3, 5, 7));
#if MODE == 2
    low = vec3(11, 13, 17);
    high = 19;
#else
    low = vec2(11, 13);
    high = vec2(17, 19);
#endif
}
