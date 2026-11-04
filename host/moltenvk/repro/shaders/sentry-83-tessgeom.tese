#version 450
layout(triangles, equal_spacing, ccw) in;
layout(location = 0) in vec3 tessPosition[];
layout(location = 0) out vec3 geometryPosition;
// Like the event, only the geometry stage writes Position and Layer.
void main() { geometryPosition = tessPosition[0]; }
