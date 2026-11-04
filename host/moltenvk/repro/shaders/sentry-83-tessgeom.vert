#version 450
// STEAMAC-83: a layered depth pass combines tessellation with geometry.
layout(location = 0) out vec3 position;
void main() { position = vec3(float(gl_VertexIndex), 0.0, 0.0); }
