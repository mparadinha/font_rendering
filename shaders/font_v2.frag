#version 420 core

in vec2 em_coords;

uniform int points_offset;
uniform int contour0_n_curves;
uniform int contour1_n_curves;

uniform isampler2D curve_point_data_tex;

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

// `idx` is in units of Points (i.e. two i16s)
vec2 getPoint(int idx) {
    int x_idx = 2 * idx;
    int y_idx = 2 * idx + 1;
    ivec2 tex_dim = textureSize(curve_point_data_tex, 0);
    ivec2 x_tex_pt = ivec2(x_idx % tex_dim.x, x_idx / tex_dim.x);
    ivec2 y_tex_pt = ivec2(y_idx % tex_dim.x, y_idx / tex_dim.x);
    return vec2(
        float(texelFetch(curve_point_data_tex, x_tex_pt, 0).r),
        float(texelFetch(curve_point_data_tex, y_tex_pt, 0).r)
    );
}

void main() {
    float alpha = 0;

    int pt_idx = points_offset;

    int curve_start_pt_idx = pt_idx;
    for (int c_idx = 0; c_idx < contour0_n_curves; c_idx++) {
        vec2 p0 = getPoint(pt_idx++);
        vec2 p1 = getPoint(pt_idx++);
        vec2 p2 = getPoint((c_idx == contour0_n_curves - 1) ? curve_start_pt_idx : pt_idx);
        alpha += curve_contribution(em_coords, p0, p1, p2);
    }
    curve_start_pt_idx = pt_idx;
    for (int c_idx = 0; c_idx < contour1_n_curves; c_idx++) {
        vec2 p0 = getPoint(pt_idx++);
        vec2 p1 = getPoint(pt_idx++);
        vec2 p2 = getPoint((c_idx == contour1_n_curves - 1) ? curve_start_pt_idx : pt_idx);
        alpha += curve_contribution(em_coords, p0, p1, p2);
    }

    FragColor = vec4(0, 0, 0, abs(alpha));
}
