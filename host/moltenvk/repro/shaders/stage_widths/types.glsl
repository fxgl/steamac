// STEAMAC-2M/88: constant, exactly representable lanes make truncation observable.
#if KIND == 0
#define SCALAR float
#define V2 vec2
#define V3 vec3
#define V4 vec4
#define C0 0.125
#define C1 0.25
#define C2 0.5
#define C3 0.75
#if MODE == 1
#define INTERPOLATION centroid
#elif MODE == 2
#define INTERPOLATION noperspective
#else
#define INTERPOLATION smooth
#endif
#elif KIND == 1
#define SCALAR uint
#define V2 uvec2
#define V3 uvec3
#define V4 uvec4
#define C0 13u
#define C1 29u
#define C2 47u
#define C3 61u
#define INTERPOLATION flat
#else
#define SCALAR int
#define V2 ivec2
#define V3 ivec3
#define V4 ivec4
#define C0 13
#define C1 29
#define C2 47
#define C3 61
#define INTERPOLATION flat
#endif

#ifdef FRAGMENT
// The driver chooses zero only for lanes never written by the producer.
#if PWIDTH < 4
#undef C3
#define C3 0
#endif
#if PWIDTH < 3
#undef C2
#define C2 0
#endif
#if PWIDTH < 2
#undef C1
#define C1 0
#endif
#endif

#if WIDTH == 1
#define VALUE SCALAR
#define CONSTANT_VALUE VALUE(C0)
#define EQUAL(a, b) ((a) == (b))
#elif WIDTH == 2
#define VALUE V2
#define CONSTANT_VALUE VALUE(C0, C1)
#define EQUAL(a, b) all(equal((a), (b)))
#elif WIDTH == 3
#define VALUE V3
#define CONSTANT_VALUE VALUE(C0, C1, C2)
#define EQUAL(a, b) all(equal((a), (b)))
#else
#define VALUE V4
#define CONSTANT_VALUE VALUE(C0, C1, C2, C3)
#define EQUAL(a, b) all(equal((a), (b)))
#endif
