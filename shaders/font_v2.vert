#version 330 core

layout (location = 0) in vec2 pos;
layout (location = 1) in vec2 pass_em_coords;
layout (location = 2) in float pass_glyph_data_offset;

uniform float zoom_mult;
uniform vec2 pan_offset;

out vec2 em_coords;
out float glyph_data_offset;

void main() {
    vec2 transformed_pos = (zoom_mult * pos) + pan_offset;
    gl_Position = vec4(transformed_pos, 0, 1);

    em_coords = pass_em_coords;
    glyph_data_offset = pass_glyph_data_offset;
}
