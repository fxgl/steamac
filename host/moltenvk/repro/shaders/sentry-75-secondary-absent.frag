#version 450
// STEAMAC-75 recurrence: SRC1 blend factors are legal even with no Index=1 output.
layout(location = 0) out vec4 primary_color;
void main() { primary_color = vec4(0.25, 0.5, 0.75, 0.5); }
