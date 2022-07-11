#version 330 core

in vec2 quad_local_pos;

uniform int xmin;
uniform int ymin;
uniform int xmax;
uniform int ymax;
uniform uint n_contours;

uniform isampler1D texture_data;

out vec4 FragColor;

// ray (for instersection) always starts at em_pos and goes in +x direction

// clockwise winding intersection is +1, counter-clockwise -1, no intersection 0

int windingIntersectLine(vec2 em_pos, vec2 start, vec2 end) {
    // check if ray (in +x direction) is parallel
    if ((end - start).y == 0) return 0;

    float t = (em_pos.y - start.y) / (end.y - start.y);

    vec2 intersect_pt = start + (end - start) * t;
    if (intersect_pt.x < em_pos.x) return 0;

    if (t < 0 || t > 1) return 0;
    if (start.y > end.y) return 1;
    return -1;
}

vec2 point_in_curve(vec2 p0, vec2 p1, vec2 p2, float t) {
    return (1 - 2 * t + t*t) * p0 + 2*t * (1 - t) * p1 + t*t * p2; 
}

int windingIntersectCurve(vec2 em_pos, vec2 p0, vec2 p1, vec2 p2) {
    // quadratic bezier curve is defined as parametric curve:
    // a point C belongs to curve if: C = (1 - 2t + t^2) p0 + 2t (1 - t) p1 + t^2 p2, for t in [0,1]
    // you can get it from doing nested lerps between p0, p1, and p2 like this
    // C = lerp( lerp(p0, p1, t), lerp(p1, p2, t), t )
    // see Freya Holmér's video on bezier curves: https://www.youtube.com/watch?v=aVwxzDHniEw

    // the ray starting from em_pos in +x direction
    // intersection when em_pos.y = C.y
    // solving for t we get quadratic formula with these values:
    float a = p0.y - 2 * p1.y + p2.y;
    float b = -2 * (p0.y - p1.y);
    float c = p0.y - em_pos.y;

    float delta = (b * b) - (4 * a * c);

    // no solutions for intersection
    if (delta < 0) return 0;

    bool curve_goes_down = (p0.y >= p1.y && p1.y >= p2.y);
    int winding = curve_goes_down ? 1 : -1;

    // 1 solution, but might be outside of t [0,1]
    if (delta == 0) {
        float t = -b / (2 * a);
        if (t < 0 || t > 1) return 0;
        return winding;
    }

    // 2 solutions
    float sol0 = (-b - sqrt(delta)) / (2 * a);
    float sol1 = (-b + sqrt(delta)) / (2 * a);

    float sol0_x = point_in_curve(p0, p1, p2, sol0).x;
    float sol1_x = point_in_curve(p0, p1, p2, sol1).x;

    bool sol0_valid = (sol0 >= 0 && sol0 <= 1) && (sol0_x >= em_pos.x);
    bool sol1_valid = (sol1 >= 0 && sol1 <= 1) && (sol1_x >= em_pos.x);

    if (sol0_valid && sol1_valid) return 0;
    else if (!sol0_valid && !sol1_valid) return 0;
    else return winding;
}

int getData(int idx) { return texelFetch(texture_data, idx, 0).r; }

int do_contours(vec2 em_pos) {
    int winding_cnt = 0;

    int data_idx = 0;
    for (int contour_idx = 0; contour_idx < int(n_contours); contour_idx++) {
        int n_segments = getData(data_idx++);
        for (int seg_idx = 0; seg_idx < n_segments; seg_idx++) {
            int seg_type = getData(data_idx++);
            if (seg_type == 0) { // line
                vec2 start = vec2(
                    float(getData(data_idx++)),
                    float(getData(data_idx++))
                );
                vec2 end = vec2(
                    float(getData(data_idx++)),
                    float(getData(data_idx++))
                );
                winding_cnt += windingIntersectLine(em_pos, start, end);
            } else if (seg_type == 1) { // curve
                vec2 start = vec2(
                    float(getData(data_idx++)),
                    float(getData(data_idx++))
                );
                vec2 control = vec2(
                    float(getData(data_idx++)),
                    float(getData(data_idx++))
                );
                vec2 end = vec2(
                    float(getData(data_idx++)),
                    float(getData(data_idx++))
                );
                winding_cnt += windingIntersectCurve(em_pos, start, control, end);
            }
        }
    }

    return winding_cnt;
}

vec4 whiteIf(bool expr) {
    if (expr) return vec4(1, 1, 1, 1);
    else return vec4(0, 0, 0, 1);
}

void main() {
    vec2 em_space_size = vec2(xmax - xmin, ymax - ymin);
    vec2 em_space_start = vec2(xmin, ymin);
    vec2 pixel_em_pos = em_space_start + quad_local_pos * em_space_size;

    int pixel_winding_cnt = do_contours(pixel_em_pos);
    if (pixel_winding_cnt == 0) {
        FragColor = vec4(0);
    } else {
        FragColor = vec4(0, 0, 0, 1);
    }
}
