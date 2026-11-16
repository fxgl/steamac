#version 450
#if WIDTH == 3
#define VALUE vec3
#else
#define VALUE vec4
#endif

#if MODE == 1
in Block {
    layout(location = 0) VALUE linked;
    layout(location = 2, component = 0) vec2 low;
    layout(location = 2, component = 2) vec2 high;
} data;
#define linked data.linked
#define low data.low
#define high data.high
#else
layout(location = 0) in VALUE linked;
#if MODE == 2
layout(location = 2, component = 0) in vec3 low;
layout(location = 2, component = 3) in float high;
#else
layout(location = 2, component = 0) in vec2 low;
layout(location = 2, component = 2) in vec2 high;
#endif
#endif
layout(location = 0) out vec4 color;

void main()
{
    bool good = all(equal(linked.xyz, vec3(2, 3, 5)));
#if WIDTH == 4
    good = good && linked.w == (PWIDTH == 4 ? 7.0 : 0.0);
#endif
#if MODE == 2
    good = good && all(equal(low, vec3(11, 13, 17))) && high == 19;
#else
    good = good && all(equal(low, vec2(11, 13))) && all(equal(high, vec2(17, 19)));
#endif
    color = good ? vec4(0.25, 0.5, 0.75, 1.0) : vec4(1.0, 0.0, 0.0, 1.0);
}
