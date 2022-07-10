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

int windingIntersectCurve(vec2 em_pos, vec2 p1, vec2 p2, vec2 p3) {
    return int(em_pos.x);
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
