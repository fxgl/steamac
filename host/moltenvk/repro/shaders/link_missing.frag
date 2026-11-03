#version 450
layout(location = 3) in vec4 missingVarying;
layout(location = 0) out vec4 color;
// Expand to a small shader with a meaningful middle, outside the old 80/40 excerpt.
// No optimizer is requested by run.sh; each assignment remains a distinct MSL line.
#define STEP color = sin(color) + missingVarying;
#define STEP10 STEP STEP STEP STEP STEP STEP STEP STEP STEP STEP
#define STEP80 STEP10 STEP10 STEP10 STEP10 STEP10 STEP10 STEP10 STEP10
void main()
{
    color = missingVarying;
    STEP80
    float fullSourceMiddle = color.x;
    color += vec4(fullSourceMiddle);
    STEP80
}
