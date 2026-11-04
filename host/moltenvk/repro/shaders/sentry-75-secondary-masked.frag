#version 450
// Matches the event shape: the second color is an unused attachment, not Index=1.
layout(location = 0) out vec4 primary_color;
layout(location = 1) out vec4 unused_color;
void main()
{
    primary_color = vec4(0.25, 0.5, 0.75, 0.5);
    unused_color = vec4(0.5, 0.25, 1.0, 0.25);
}
