#version 330 core

in vec2 quad_local_pos;

uniform vec2 viewport_size;
uniform float zoom_mult;
uniform int xmin;
uniform int ymin;
uniform int xmax;
uniform int ymax;
uniform uint n_contours;

uniform isampler1D texture_data;

out vec4 FragColor;

vec2 em_space_size = vec2(xmax - xmin, ymax - ymin);
vec2 em_space_start = vec2(xmin, ymin);
// TODO: this assumes that glyph quad is perfectly square
float ems_per_pixel = (em_space_size / (2 * viewport_size * zoom_mult)).x;

vec2 point_in_line(vec2 p0, vec2 p1, float t) {
    return (1 - t) * p0 + t * p1;
}
vec2 point_in_curve(vec2 p0, vec2 p1, vec2 p2, float t) {
    return (1 - 2 * t + t*t) * p0 + 2*t * (1 - t) * p1 + t*t * p2; 
}

float sat(float value) { return clamp(value, 0, 1); }
//float f(float value) { return sat((value / ems_per_pixel) + 0.5f); }
float f(float value) { return sat(value / ems_per_pixel); }

// ray (for instersection) always starts at em_pos and goes in +x direction
// (unless it a xxxxVert function which does +y rays)
// clockwise winding intersection is +1, counter-clockwise -1, no intersection 0

float windingIntersectLine(vec2 em_pos, vec2 start, vec2 end) {
    // check if ray (in +x direction) is parallel
    if ((end - start).y == 0) return 0.0f;

    float t = (em_pos.y - start.y) / (end.y - start.y);

    vec2 intersect_pt = start + (end - start) * t;
    if (intersect_pt.x < em_pos.x) return 0.0f;

    if (t < 0 || t > 1) return 0.0f;
    if (start.y > end.y) return f(intersect_pt.x - em_pos.x);
    return -f(intersect_pt.x - em_pos.x);
}

float windingIntersectLineVert(vec2 em_pos, vec2 start, vec2 end) {
    // check if ray (in +y direction) is parallel
    if ((end - start).x == 0) return 0.0f;

    float t = (em_pos.x - start.x) / (end.x - start.x);

    vec2 intersect_pt = start + (end - start) * t;
    if (intersect_pt.y < em_pos.y) return 0.0f;

    if (t < 0 || t > 1) return 0.0f;
    if (start.x > end.x) return f(intersect_pt.y - em_pos.y);
    return -f(intersect_pt.y - em_pos.y);
}

float windingIntersectCurve(vec2 em_pos, vec2 p0, vec2 p1, vec2 p2) {
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
    if (delta < 0) return 0.0f;

    bool curve_goes_down = (p0.y >= p1.y && p1.y >= p2.y);
    float winding = curve_goes_down ? 1 : -1;

    // 1 solution, but might be outside of t [0,1]
    if (delta == 0) {
        float t = -b / (2 * a);
        if (t < 0 || t > 1) return 0.0f;
        return winding * f(point_in_curve(p0, p1, p2, t).x - em_pos.x);
    }

    // 2 solutions
    float sol0 = (-b - sqrt(delta)) / (2 * a);
    float sol1 = (-b + sqrt(delta)) / (2 * a);

    float sol0_x = point_in_curve(p0, p1, p2, sol0).x;
    float sol1_x = point_in_curve(p0, p1, p2, sol1).x;

    bool sol0_valid = (sol0 >= 0 && sol0 <= 1) && (sol0_x >= em_pos.x);
    bool sol1_valid = (sol1 >= 0 && sol1 <= 1) && (sol1_x >= em_pos.x);

    if (sol0_valid && sol1_valid) {
        return winding * f(sol0_x - em_pos.x) - winding * f(sol1_x - em_pos.x);
    } else if (!sol0_valid && !sol1_valid) {
        return 0.0f;
    } else {
        float sol_x = sol0_valid ? sol0_x : sol1_x;
        return winding * f(sol_x - em_pos.x);
    }
}

float windingIntersectCurveVert(vec2 em_pos, vec2 p0, vec2 p1, vec2 p2) {
    float a = p0.x - 2 * p1.x + p2.x;
    float b = -2 * (p0.x - p1.x);
    float c = p0.x - em_pos.x;

    float delta = (b * b) - (4 * a * c);

    if (delta < 0) return 0.0f;

    bool curve_goes_down = (p0.x >= p1.x && p1.x >= p2.x);
    float winding = curve_goes_down ? 1 : -1;

    if (delta == 0) {
        float t = -b / (2 * a);
        if (t < 0 || t > 1) return 0.0f;
        return winding * f(point_in_curve(p0, p1, p2, t).y - em_pos.y);
    }

    float sol0 = (-b - sqrt(delta)) / (2 * a);
    float sol1 = (-b + sqrt(delta)) / (2 * a);

    float sol0_x = point_in_curve(p0, p1, p2, sol0).y;
    float sol1_x = point_in_curve(p0, p1, p2, sol1).y;

    bool sol0_valid = (sol0 >= 0 && sol0 <= 1) && (sol0_x >= em_pos.y);
    bool sol1_valid = (sol1 >= 0 && sol1 <= 1) && (sol1_x >= em_pos.y);

    if (sol0_valid && sol1_valid) {
        return winding * f(sol0_x - em_pos.y) - winding * f(sol1_x - em_pos.y);
    } else if (!sol0_valid && !sol1_valid) {
        return 0.0f;
    } else {
        float sol_x = sol0_valid ? sol0_x : sol1_x;
        return winding * f(sol_x - em_pos.y);
    }
}

const float basically_pos_inf = 1E30;

float distanceToLine(vec2 point, vec2 start, vec2 end) {
    if (start.x == end.x) { // vertical line
        float t = (point.y - start.y) / (end.y - start.y);
        if (t >= 0 && t <= 1) return abs(start.x - point.x);
        else return basically_pos_inf;
    }
    if (start.y == end.y) { // horizontal line
        float t = (point.x - start.x) / (end.x - start.x);
        if (t >= 0 && t <= 1) return abs(start.y - point.y);
        else return basically_pos_inf;
    }

    float m = (end.y - start.y) / (end.x - start.x);
    float m_per = -1/m;
    float b = end.y - m * end.x;
    float b_per = point.y - m_per * point.x;
    float x = (b_per - b) / (m - m_per);
    float t = (x - start.x) / (end.x - start.x);
    if (t >= 0 && t <= 1) return distance(point, point_in_line(start, end, t));
    else return basically_pos_inf;
}

// the other version was getting too complicated. just do a search in t to find closest point
// (the distance function is not usually monotonic so this cant guarantee to find the global min)
float distanceToCurve(vec2 point, vec2 p0, vec2 p1, vec2 p2) {
    int depth = 5;
    float bottom_t = 0, top_t = 1;
    float t_smallest = bottom_t;
    for (int i = 0; i < depth; i++) {
        float gap = top_t - bottom_t;
        for (float w = 0; w < 1; w += 0.1f) {
            float t = bottom_t + (top_t - bottom_t) * w;
            float t_dist = distance(point, point_in_curve(p0, p1, p2, t));
            float smallest_dist = distance(point, point_in_curve(p0, p1, p2, t_smallest));
            if (t_dist < smallest_dist) t_smallest = t;
        }
        bottom_t = t_smallest - gap * 0.1f;
        top_t = t_smallest + gap * 0.1f;
    }

    return distance(point, point_in_curve(p0, p1, p2, t_smallest));
}
//float distanceToCurve(vec2 point, vec2 p0, vec2 p1, vec2 p2) {
//    // determining the distance to a quadratic curve means solving a 3rd degree
//    // polynomial, which we get by doing d/dt (dist) = 0, where
//    // dist = sqrt(dot(C - point, C - point))
//    // and C is the parametric equation for the quadratic bezier curve.
//
//    // in the form a * t^3 + b * t^2 + c * t + d = 0 we have:
//    float dot00 = dot(p0, p0);
//    float dot01 = dot(p0, p1);
//    float dot02 = dot(p0, p2);
//    float dot11 = dot(p1, p1);
//    float dot12 = dot(p1, p2);
//    float dot22 = dot(p2, p2);
//    float a = 2*dot00 - 8*dot11 + 2*dot22 + 4*dot02 - 8*dot12;
//    float b = -6*dot00 - 12*dot11 + 18*dot01 - 6*dot02 + 6*dot12;
//    float c = 6*dot00 + 4*dot11 - 12*dot01 + 2*dot02 + dot(point, -2 * p0 + 4 * p1 - 2 * p2);
//    float d = -2*dot00 + 2*dot01 + dot(point, 2 * p0 - 2 * p1);
//
//    // https://en.wikipedia.org/wiki/Cubic_equation#General_cubic_formula
//    // https://en.wikipedia.org/wiki/Cubic_equation#Discriminant_and_nature_of_the_roots
//
//    float delta0 = pow(b, 2) - 3 * a * c;
//    float delta1 = 2 * pow(b, 3) - 9 * a * b * c + 27 * pow(a, 2) * d;
//    float discrim = (4 * pow(delta0, 3) - delta0) / (27 * pow(a, 2));
//    float C_sqrt_part = pow(delta1, 2) - 4 * pow(delta0, 3);
//    float C_1 = pow((delta1 - sqrt(C_sqrt_part)) / 2, 1.0f/3.0f);
//    float C_2 = pow((delta1 + sqrt(C_sqrt_part)) / 2, 1.0f/3.0f);
//    float C = C_1 == 0 ? C_2 : C_1;
//
//    float root0 = 0, root1 = 0, root2 = 0;
//    int n_real_roots = 0;
//
//    if (discrim > 0) { // three distinct real roots
//        n_real_roots = 3;
//        float minus_1_3a = -1 / (3 * a);
//        float delta_C = delta0 / C;
//        root0 = minus_1_3a * (b + C + delta_C);
//        root1 = minus_1_3a * (b - C);
//        root2 = minus_1_3a * (b - delta_C);
//    } else if (discrim < 0) { // one real root, two imaginary
//        n_real_roots = 1;
//        root0 = (-1 / (3 * a)) * (b + C + (delta0 / C)); 
//    } else { // multiple root
//        if (pow(b, 2) == 3 * a * c) { // triple root
//            n_real_roots = 1;
//            root0 = -b / (3 * a);
//        } else { // double root and a simple root
//            n_real_roots = 2;
//            root0 = (9*a*d - b * c) / (2 * delta0);
//            root1 = (4*a*c - 9 * pow(a, 2) * d - pow(b, 3)) / (a * delta0);
//        }
//    }
//
//
//    if (n_real_roots == 1) {
//        vec2 curve_pt = point_in_curve(p0, p1, p2, root0);
//        return distance(curve_pt, point);
//    }
//    if (n_real_roots == 2) {
//        float dist0 = distance(point, point_in_curve(p0, p1, p2, root0));
//        float dist1 = distance(point, point_in_curve(p0, p1, p2, root1));
//        return min(dist0, dist1);
//    }
//    if (n_real_roots == 3) {
//        return 0.5f;
//        float dist0 = distance(point, point_in_curve(p0, p1, p2, root0));
//        float dist1 = distance(point, point_in_curve(p0, p1, p2, root1));
//        float dist2 = distance(point, point_in_curve(p0, p1, p2, root2));
//        return min(min(dist0, dist1), min(dist1, dist2));
//    }
//
//    return 1.0f;
//
//    return basically_pos_inf;
//}

int getData(int idx) { return texelFetch(texture_data, idx, 0).r; }


// returns alpha we should apply to this pixel. 1 means fully inside glyph shape
// 0 means fully outside.
float do_contours(vec2 em_pos) {
    float winding_cnt = 0;

    int data_idx = 0;
    for (int contour_idx = 0; contour_idx < int(n_contours); contour_idx++) {
        int n_segments = getData(data_idx++);
        for (int seg_idx = 0; seg_idx < n_segments; seg_idx++) {
            int seg_type = getData(data_idx++);
            vec2 start = vec2(
                float(getData(data_idx++)),
                float(getData(data_idx++))
            );
            if (seg_type == 0) { // line
                vec2 end = vec2(
                    float(getData(data_idx++)),
                    float(getData(data_idx++))
                );
                float intersect_res = windingIntersectLine(em_pos, start, end);
                intersect_res += -1.0f * windingIntersectLineVert(em_pos, start, end);
                winding_cnt += intersect_res;
            } else if (seg_type == 1) { // curve
                vec2 control = vec2(
                    float(getData(data_idx++)),
                    float(getData(data_idx++))
                );
                vec2 end = vec2(
                    float(getData(data_idx++)),
                    float(getData(data_idx++))
                );
                float intersect_res = windingIntersectCurve(em_pos, start, control, end);
                intersect_res += -1.0f * windingIntersectCurveVert(em_pos, start, control, end);
                winding_cnt += intersect_res;
            }
        }
    }

    return winding_cnt / 2;
}

vec4 whiteIf(bool expr) {
    if (expr) return vec4(1, 1, 1, 1);
    else return vec4(0, 0, 0, 1);
}

void main() {
    vec2 pixel_em_pos = em_space_start + quad_local_pos * em_space_size;

    float alpha_cnt = 0;
    int sample_cnt = 0;
    for (float offset = -0.4f; offset < 0.5f; offset += 0.1f) {
        alpha_cnt += do_contours(pixel_em_pos + ems_per_pixel * vec2(offset));
        sample_cnt++;
    }

    float alpha = sqrt(alpha_cnt / float(sample_cnt));
    FragColor = vec4(0, 0, 0, alpha);
}
