#version 450
#extension GL_GOOGLE_include_directive : require
#define FRAGMENT
#include "types.glsl"

#if MODE == 0
layout(location = 0, component = COMPONENT) INTERPOLATION in VALUE data;
#if COMPONENT != 0
layout(location = 0, component = 0) INTERPOLATION in SCALAR neighbour;
#endif
#elif MODE == 1
layout(location = 0) INTERPOLATION in VALUE data[2];
#else
layout(location = 0) in Block { INTERPOLATION VALUE data; INTERPOLATION VALUE pair[2]; } blockData;
#endif
layout(location = 0) out vec4 color;

void main()
{
#if MODE == 0
    bool good = EQUAL(data, CONSTANT_VALUE);
#if COMPONENT != 0
    good = good && neighbour == SCALAR(7);
#endif
#elif MODE == 1
    bool good = EQUAL(data[0], CONSTANT_VALUE) && EQUAL(data[1], CONSTANT_VALUE);
#else
    bool good = EQUAL(blockData.data, CONSTANT_VALUE) &&
                EQUAL(blockData.pair[0], CONSTANT_VALUE) && EQUAL(blockData.pair[1], CONSTANT_VALUE);
#endif
    color = good ? vec4(0.25, 0.5, 0.75, 1.0) : vec4(1.0, 0.0, 0.0, 1.0);
}
