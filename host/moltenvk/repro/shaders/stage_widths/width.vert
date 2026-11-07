#version 450
#extension GL_GOOGLE_include_directive : require
#include "types.glsl"

#if MODE == 0
layout(location = 0, component = COMPONENT) INTERPOLATION out VALUE data;
#if COMPONENT != 0
layout(location = 0, component = 0) INTERPOLATION out SCALAR neighbour;
#endif
#elif MODE == 1
layout(location = 0) INTERPOLATION out VALUE data[2];
#else
layout(location = 0) out Block { INTERPOLATION VALUE data; INTERPOLATION VALUE pair[2]; } blockData;
#endif

void main()
{
    vec2 positions[3] = vec2[3](vec2(-1, -1), vec2(3, -1), vec2(-1, 3));
    gl_Position = vec4(positions[gl_VertexIndex], 0.5, 1.0);
#if MODE == 0
    data = CONSTANT_VALUE;
#if WIDTH > 1
    // Reading/writing an output component must continue to use its logical vector type.
    data.x = data.x;
#endif
#if COMPONENT != 0
    neighbour = SCALAR(7);
#endif
#elif MODE == 1
    data[0] = CONSTANT_VALUE;
    data[1] = CONSTANT_VALUE;
#else
    blockData.data = CONSTANT_VALUE;
    blockData.pair[0] = CONSTANT_VALUE;
    blockData.pair[1] = CONSTANT_VALUE;
#endif
}
