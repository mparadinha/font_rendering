#version 330 core

layout (location = 0) in vec2 pos;
layout (location = 1) in vec2 local_pos;

uniform float zoom_mult;
uniform vec2 pan_offset;

out vec2 quad_local_pos;

void main() {
    vec2 transformed_pos = (zoom_mult * pos) + pan_offset;
    gl_Position = vec4(transformed_pos, 0, 1);
    quad_local_pos = local_pos;
}
