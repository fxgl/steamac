#version 450
// Block and standalone declarations must expose identical Location/Component pairs.
#ifndef VERTEX
#define VERTEX 0
#endif
#ifndef BLOCK
#define BLOCK 1
#endif
#ifndef SHAPE
#define SHAPE 0
#endif
#if VERTEX
#define IO out
#else
#define IO in
layout(location = 0) out vec4 color;
#endif
#if BLOCK
IO Interface {
#endif
#if SHAPE == 0
#if BLOCK
    layout(location = 0) vec4 coordinate;
    layout(location = 2) flat uint tag;
#else
layout(location = 0) IO vec4 coordinate;
layout(location = 2) flat IO uint tag;
#endif
#elif SHAPE == 1
#if BLOCK
    layout(location = 1) vec2 coordinates[2];
    layout(location = 5) mat3 basis;
    layout(location = 10) vec4 tail;
#else
layout(location = 1) IO vec2 coordinates[2];
layout(location = 5) IO mat3 basis;
layout(location = 10) IO vec4 tail;
#endif
#elif SHAPE == 2
#if BLOCK
    layout(location = 0, component = 0) vec2 low;
    layout(location = 0, component = 2) vec2 high;
    layout(location = 3) float tail;
#else
layout(location = 0, component = 0) IO vec2 low;
layout(location = 0, component = 2) IO vec2 high;
layout(location = 3) IO float tail;
#endif
#else
#if BLOCK
    layout(location = 0) vec2 first;
    layout(location = 3) vec3 last;
    layout(location = 1) vec3 middle;
    layout(location = 2) vec4 other;
#else
layout(location = 0) IO vec2 first;
layout(location = 3) IO vec3 last;
layout(location = 1) IO vec3 middle;
layout(location = 2) IO vec4 other;
#endif
#endif
#if BLOCK
} data;
#define FIELD(x) data.x
#else
#define FIELD(x) x
#endif
void main()
{
#if VERTEX
    gl_Position = vec4(0.0, 0.0, 0.0, 1.0);
#if SHAPE == 0
    FIELD(coordinate) = vec4(0.25);
    FIELD(tag) = 7u;
#elif SHAPE == 1
    FIELD(coordinates)[0] = vec2(0.1);
    FIELD(coordinates)[1] = vec2(0.2);
    FIELD(basis) = mat3(1.0);
    FIELD(tail) = vec4(0.3);
#elif SHAPE == 2
    FIELD(low) = vec2(0.1);
    FIELD(high) = vec2(0.2);
    FIELD(tail) = 0.3;
#else
    FIELD(first) = vec2(0.1);
    FIELD(last) = vec3(0.2);
    FIELD(middle) = vec3(0.3);
    FIELD(other) = vec4(0.4);
#endif
#else
#if SHAPE == 0
    color = FIELD(coordinate) + vec4(float(FIELD(tag)));
#elif SHAPE == 1
    color = vec4(FIELD(coordinates)[0] + FIELD(coordinates)[1], 0.0, 0.0) +
        vec4(FIELD(basis)[0] + FIELD(basis)[1] + FIELD(basis)[2], 0.0) + FIELD(tail);
#elif SHAPE == 2
    color = vec4(FIELD(low), FIELD(high)) + vec4(FIELD(tail));
#else
    color = vec4(FIELD(first), 0.0, 0.0) + vec4(FIELD(last) + FIELD(middle), 0.0) + FIELD(other);
#endif
#endif
}
