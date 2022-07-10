const std = @import("std");

/// convert degrees into radians
pub fn to_radians(x: anytype) @TypeOf(x) {
    return (x * std.math.pi) / 180;
}

pub const vec2 = @Vector(2, f32);
pub const vec3 = @Vector(3, f32);
pub const vec4 = @Vector(4, f32);

pub fn splat(comptime VecType: type, scalar: std.meta.Child(VecType)) VecType {
    const info = @typeInfo(VecType).Vector;
    return @splat(info.len, @as(info.child, scalar));
}

pub fn zeroes(comptime VecType: type) VecType {
    return splat(VecType, 0);
}

pub fn axis_vec(axis: enum { x, y, z }) vec3 {
    return switch (axis) {
        .x => [3]f32{ 1, 0, 0 },
        .y => [3]f32{ 0, 1, 0 },
        .z => [3]f32{ 0, 0, 1 },
    };
}

pub fn times(vec: anytype, scalar: std.meta.Child(@TypeOf(vec))) @TypeOf(vec) {
    return vec * splat(@TypeOf(vec), scalar);
}

pub fn div(vec: anytype, scalar: std.meta.Child(@TypeOf(vec))) @TypeOf(vec) {
    return vec / splat(@TypeOf(vec), scalar);
}

pub fn dot(vec_a: anytype, vec_b: @TypeOf(vec_a)) std.meta.Child(@TypeOf(vec_a)) {
    const mult = vec_a * vec_b;
    return @reduce(.Add, mult);
}

pub fn size(vec: anytype) f32 {
    const info = @typeInfo(@TypeOf(vec));
    std.debug.assert(std.meta.activeTag(info) == .Vector);
    std.debug.assert(info.Vector.child != f64);
    return std.math.sqrt(dot(vec, vec));
}

pub fn normalize(vec: anytype) @TypeOf(vec) {
    const info = @typeInfo(@TypeOf(vec));
    std.debug.assert(std.meta.activeTag(info) == .Vector);
    const vec_size = size(vec);
    return if (vec_size == 0) vec else vec / splat(@TypeOf(vec), vec_size);
}

pub fn cross(vec_a: anytype, vec_b: @TypeOf(vec_a)) @TypeOf(vec_a) {
    const info = @typeInfo(@TypeOf(vec_a)).Vector;
    std.debug.assert(info.len == 3);
    return [3]info.child{
        (vec_a[1] * vec_b[2]) - (vec_a[2] * vec_b[1]),
        (vec_a[2] * vec_b[0]) - (vec_a[0] * vec_b[2]),
        (vec_a[0] * vec_b[1]) - (vec_a[1] * vec_b[0]),
    };
}

/// Matrices are stored in column-major form
pub const mat2 = @Vector(2 * 2, f32);
pub const mat3 = @Vector(3 * 3, f32);
pub const mat4 = @Vector(4 * 4, f32);

/// only for square matrices
pub fn mat_mult(mat_a: anytype, mat_b: @TypeOf(mat_a)) @TypeOf(mat_a) {
    const info = @typeInfo(@TypeOf(mat_a)).Vector;
    const dim = perfect_sqrt(info.len) orelse unreachable;

    var res: mat4 = undefined;
    var i: usize = 0;
    while (i < dim) : (i += 1) {
        var j: usize = 0;
        while (j < dim) : (j += 1) {
            var dot_sum: info.child = 0;
            var k: usize = 0;
            while (k < dim) : (k += 1) dot_sum += mat_a[k * dim + j] * mat_b[i * dim + k];
            res[i * dim + j] = dot_sum;
        }
    }
    return res;
}

pub fn identity(MatType: type) MatType {
    const info = @typeInfo(MatType);
    const dim = perfect_sqrt(info.len) orelse unreachable;
    var mat = splat(MatType, 0);
    var i: usize = 0;
    while (i < dim) : (i += 1) mat[i * dim + i] = 1;
    return mat;
}

// zig fmt: off
pub fn translation(delta: vec3) mat4 {
    return [4 * 4]f32 {
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        delta[0], delta[1], delta[2], 1,
    };
}

pub fn scale(scale_vec: vec3) mat4 {
    return [4 * 4]f32 {
        scale_vec[0], 0, 0, 0,
        0, scale_vec[1], 0, 0,
        0, 0, scale_vec[2], 0,
        0, 0, 0, 1,
    };
}

/// `user_angle` is in degrees
pub fn rotation(user_axis: vec3, user_angle: f32) mat4 {
    const axis = user_axis.normalized().data;
    const angle = to_radians(user_angle);

    // https://en.wikipedia.org/wiki/Rotation_matrix#Rotation_matrix_from_axis_and_angle
    const c: f32 = 1 - @cos(angle);
    return [4 * 4]f32{
        @cos(angle) + axis[0] * axis[0] * c,
        axis[0] * axis[1] * c + axis[2] * @sin(angle),
        axis[0] * axis[1] * c - axis[1] * @sin(angle),
        0,

        axis[0] * axis[1] * c - axis[2] * @sin(angle),
        @cos(angle) + axis[1] * axis[1] * c,
        axis[2] * axis[1] * c + axis[0] * @sin(angle),
        0,

        axis[0] * axis[2] * c + axis[1] * @sin(angle),
        axis[1] * axis[2] * c - axis[0] * @sin(angle),
        @cos(angle) + axis[2] * axis[2] * c,
        0,

        0, 0, 0, 1,
    };
}

pub fn projection(fov: f32, ratio: f32, near: f32, far: f32) mat4 {
    var mat = splat(mat4, 0);
    // https://www.songho.ca/opengl/gl_projectionmatrix.html
    const half_tan_fov = std.math.tan(fov * std.math.pi / 360.0);
    mat[0 * 4 + 0] = 1 / (ratio * half_tan_fov);
    mat[1 * 4 + 1] = 1 / half_tan_fov;
    mat[2 * 4 + 2] = (near + far) / (near - far);
    mat[2 * 4 + 3] = -1;
    mat[3 * 4 + 2] = (2 * near * far) / (near - far);
    return mat;
}

/// `user_yaw` and `user_pitch` are in degress
/// yaw starts at -z axis and rotates around +y according to right hand rule
/// pitch is the angle with the xz plane
pub fn view(pos: vec3, user_yaw: f32, user_pitch: f32) mat4 {
    const yaw = to_radians(user_yaw);
    const pitch = to_radians(user_pitch);

    const x: vec3 = [3]f32{ @cos(yaw), 0, -@sin(yaw) };
    const y: vec3 = [3]f32{ @sin(yaw) * @sin(pitch), @cos(pitch), @cos(yaw) * @sin(pitch) };
    const z: vec3 = [3]f32{ @sin(yaw) * @cos(pitch), -@sin(pitch), @cos(pitch) * @cos(yaw) };
    const dots = [3]f32{ dot(x, pos), dot(y, pos), dot(z, pos) };

    return [4 * 4]f32{
        x[0], y[0], z[0], 0,
        x[1], y[1], z[1], 0,
        x[2], y[2], z[2], 0,
        -dots[0], -dots[1], -dots[2], 1
    };
}
// zig fmt: on

/// Return the sqrt of `x` or `null` if `x` is not a perfect square.
fn perfect_sqrt(x: anytype) ?@TypeOf(x) {
    const info = @typeInfo(@TypeOf(x));
    const sqrt: f32 = switch (std.meta.activeTag(info)) {
        .Int, .ComptimeInt => @sqrt(@intToFloat(f32, x)),
        .Float, .ComptimeFloat => @sqrt(@floatCast(f32, x)),
        else => |tag| @compileError("can't calculate perfect for " ++ @tagName(tag)),
    };
    if (@floor(sqrt) != @ceil(sqrt)) return null;
    return switch (std.meta.activeTag(info)) {
        .Int, .ComptimeInt => @floatToInt(@TypeOf(x), sqrt),
        .Float, .ComptimeFloat => @floatCast(@TypeOf(x), sqrt),
        else => |tag| @compileError("can't calculate perfect for " ++ @tagName(tag)),
    };
}
