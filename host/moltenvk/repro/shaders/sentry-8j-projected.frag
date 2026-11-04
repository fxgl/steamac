#version 450
#extension GL_ARB_gpu_shader5 : require
// STEAMAC-8J: M1's backend cannot link iterated/projected sample-rate coordinates.
#ifndef SHAPE
#define SHAPE 0
#endif
#ifndef READ_INTERPOLANT
#define READ_INTERPOLANT 0
#endif
#if SHAPE == 2
in Block {
    layout(location = 0) sample vec4 coordinate;
    layout(location = 1) flat vec4 tag;
} input_block;
layout(location = 2) flat in uint integer_tag;
#elif SHAPE == 3
layout(location = 0) sample in vec4 coordinates[2];
#elif SHAPE == 4
layout(location = 0) sample noperspective in vec4 coordinate;
#elif SHAPE == 5
layout(location = 0) in vec4 coordinate;
#else
layout(location = 0) sample in vec4 coordinate;
#endif
layout(set = 0, binding = 0) uniform sampler2D source_texture;
layout(location = 0) out vec4 color;
#if SHAPE == 1 || SHAPE == 2
vec4 helper() {
#if SHAPE == 2
    return input_block.coordinate + input_block.tag * 0.1 + vec4(float(integer_tag - 7u));
#else
    return coordinate;
#endif
}
#endif
void main()
{
#if SHAPE == 1 || SHAPE == 2
    vec4 value = helper();
#elif SHAPE == 3
    vec4 value = coordinates[int(gl_FragCoord.x) % 2];
#elif SHAPE == 5
    vec4 value = interpolateAtSample(coordinate, gl_SampleID);
#else
    vec4 value = coordinate;
#endif
#if READ_INTERPOLANT
    color = value;
#else
    color = texture(source_texture, value.xy / value.w);
#endif
}
