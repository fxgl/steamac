#version 450
layout(location = 0, index = 0) out vec4 primary_color;
layout(location = 0, index = 1) out vec4 secondary_color[1];
void main()
{
    primary_color = vec4(0.25, 0.5, 0.75, 0.5);
    secondary_color[0] = vec4(0.5, 0.25, 1.0, 0.25);
}
