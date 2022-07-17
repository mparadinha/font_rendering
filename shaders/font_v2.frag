#version 420 core

in vec2 em_coords;
in float glyph_data_offset;

uniform isampler2D curve_point_data_tex;
uniform isampler2D glyph_data_tex;

out vec4 FragColor;

float curve_contribution(vec2 pos, vec2 start, vec2 control, vec2 end) {
    // shift stuff so that origin of the ray is (0, 0) and the math is simpler
    vec2 p0 = start - pos;
    vec2 p1 = control - pos;
    vec2 p2 = end - pos;

    // equation for bezier curve: C(t) = (1 - 2t + t^2)p0 + 2t(1 - t)p1 + t^2*p2 
    // solve for C.y(t) = 0 (ray going in the +x direction)
    // t^2 (p0 - 2p1 + p2) + t (-2p0 + 2p1) + p0 = 0
    float a = p0.y - 2 * p1.y + p2.y;
    float b = 2 * (p1.y - p0.y);
    float c = p0.y;
    float discrim = (b * b) - (4 * a * c);
    if (discrim < 0) return 0.0f;

    float t1 = (-b - sqrt(discrim)) / (2 * a);
    float t2 = (-b + sqrt(discrim)) / (2 * a);
    if (a < 0.0001) t1 = t2 = -c / b;
    float x_t1 = (1 - 2*t1 + t1*t1)*p0.x + 2*t1*(1 - t1)*p1.x + t1*t1*p2.x;
    float x_t2 = (1 - 2*t2 + t2*t2)*p0.x + 2*t2*(1 - t2)*p1.x + t2*t2*p2.x;

    bool t1_table[8] = {
        false, // p0.y <= 0; p1.y <= 0; p2.y <= 0;
         true, // p0.y >  0; p1.y <= 0; p2.y <= 0;
         true, // p0.y <= 0; p1.y >  0; p2.y <= 0;
         true, // p0.y >  0; p1.y >  0; p2.y <= 0;
        false, // p0.y <= 0; p1.y <= 0; p2.y >  0;
         true, // p0.y >  0; p1.y <= 0; p2.y >  0;
        false, // p0.y <= 0; p1.y >  0; p2.y >  0;
        false, // p0.y >  0; p1.y >  0; p2.y >  0;
    };
    bool t2_table[8] = {
        false, // p0.y <= 0; p1.y <= 0; p2.y <= 0;
        false, // p0.y >  0; p1.y <= 0; p2.y <= 0;
         true, // p0.y <= 0; p1.y >  0; p2.y <= 0;
        false, // p0.y >  0; p1.y >  0; p2.y <= 0;
         true, // p0.y <= 0; p1.y <= 0; p2.y >  0;
         true, // p0.y >  0; p1.y <= 0; p2.y >  0;
         true, // p0.y <= 0; p1.y >  0; p2.y >  0;
        false, // p0.y >  0; p1.y >  0; p2.y >  0;
    };
    bool t1_counts = t1_table[(p0.y > 0 ? 1:0) + (p1.y > 0 ? 2:0) + (p2.y > 0 ? 4:0)];
    bool t2_counts = t2_table[(p0.y > 0 ? 1:0) + (p1.y > 0 ? 2:0) + (p2.y > 0 ? 4:0)];

    float coverage = 0;
    if (t1 >= 0 && t1 < 1 && x_t1 > 0 && t1_counts) coverage += 1.0f;
    if (t2 >= 0 && t2 < 1 && x_t2 > 0 && t2_counts) coverage -= 1.0f;

    return coverage;
}

ivec2 texCoordsFromRawIdx(ivec2 tex_dim, int raw_idx) {
    return ivec2(raw_idx % tex_dim.x, raw_idx / tex_dim.x);
}

// `idx` is in units of Points (i.e. two i16s)
vec2 getPoint(int idx) {
    ivec2 tex_dim = textureSize(curve_point_data_tex, 0);
    ivec2 x_tex_coords = texCoordsFromRawIdx(tex_dim, 2 * idx);
    ivec2 y_tex_coords = texCoordsFromRawIdx(tex_dim, 2 * idx + 1);
    return vec2(
        float(texelFetch(curve_point_data_tex, x_tex_coords, 0).r),
        float(texelFetch(curve_point_data_tex, y_tex_coords, 0).r)
    );
}

int getGlyphPointOffset() {
    ivec2 tex_dim = textureSize(glyph_data_tex, 0);
    ivec2 tex_coords = texCoordsFromRawIdx(tex_dim, int(glyph_data_offset));
    return int(texelFetch(glyph_data_tex, tex_coords, 0).r);    
}

int getGlyphNContours() {
    ivec2 tex_dim = textureSize(glyph_data_tex, 0);
    ivec2 tex_coords = texCoordsFromRawIdx(tex_dim, int(glyph_data_offset) + 1);
    return int(texelFetch(glyph_data_tex, tex_coords, 0).r);    
}

int getContourNCurves(int contour_idx) {
    ivec2 tex_dim = textureSize(glyph_data_tex, 0);
    ivec2 tex_coords = texCoordsFromRawIdx(tex_dim, int(glyph_data_offset) + 2 + contour_idx);
    return int(texelFetch(glyph_data_tex, tex_coords, 0).r);    
}

void main() {
    float alpha = 0;

    int points_offset = getGlyphPointOffset();
    int pt_idx = points_offset;

    int n_contours = getGlyphNContours();
    for (int contour_idx = 0; contour_idx < n_contours; contour_idx++) {
        int curve_start_pt_idx = pt_idx;
        int contour_n_curves = getContourNCurves(contour_idx);
        for (int curve_idx = 0; curve_idx < contour_n_curves; curve_idx++) {
            vec2 p0 = getPoint(pt_idx++);
            vec2 p1 = getPoint(pt_idx++);
            vec2 p2 = getPoint((curve_idx == contour_n_curves - 1) ? curve_start_pt_idx : pt_idx);
            alpha += curve_contribution(em_coords, p0, p1, p2);
        }
    }

    FragColor = vec4(0, 0, 0, abs(alpha));
}
