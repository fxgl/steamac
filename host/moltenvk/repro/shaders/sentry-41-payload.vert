#version 450
// STEAMAC-41/R: a scalar location only initializes one lane of the old uint4 payload.
layout(push_constant) uniform Push { int index; } pc;
layout(location = 0) out vec4 position;
layout(location = 1) out vec4 color;
layout(location = 2) out float size;
void main()
{
    position = vec4(0.0, 0.0, 0.0, 1.0);
    color = vec4(0.0, float(pc.index), 0.0, 1.0);
    size = float(pc.index);
}
