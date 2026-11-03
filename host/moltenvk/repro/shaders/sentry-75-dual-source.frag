#version 450
// Valid dual-source outputs, with independently component-packed primary/secondary colors.
// Compile with -DPRIMARY_PACKED=0/1 -DSECONDARY_PACKED=0/1 to cover mixed layouts too.
#ifndef PRIMARY_PACKED
#define PRIMARY_PACKED 1
#endif
#ifndef SECONDARY_PACKED
#define SECONDARY_PACKED 1
#endif
#if PRIMARY_PACKED
layout(location = 0, index = 0, component = 0) out vec3 primary_rgb;
layout(location = 0, index = 0, component = 3) out float primary_alpha;
#else
layout(location = 0, index = 0) out vec4 primary_color;
#endif
#if SECONDARY_PACKED
layout(location = 0, index = 1, component = 0) out vec3 secondary_rgb;
layout(location = 0, index = 1, component = 3) out float secondary_alpha;
#else
layout(location = 0, index = 1) out vec4 secondary_color;
#endif
void main()
{
#if PRIMARY_PACKED
    primary_rgb = vec3(0.25, 0.5, 0.75);
    primary_alpha = 0.5;
#else
    primary_color = vec4(0.25, 0.5, 0.75, 0.5);
#endif
#if SECONDARY_PACKED
    secondary_rgb = vec3(0.5, 0.25, 1.0);
    secondary_alpha = 0.25;
#else
    secondary_color = vec4(0.5, 0.25, 1.0, 0.25);
#endif
}
