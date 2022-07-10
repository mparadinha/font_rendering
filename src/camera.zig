const std = @import("std");

const math = @import("math.zig");
const vec2 = math.vec2;
const vec3 = math.vec3;
const mat4 = math.mat4;
const gfx = @import("graphics.zig");

pub const ArcBall = struct {
    target: vec3,
    dist: f32,

    /// angles in degrees
    horizontal_angle: f32,
    vertical_angle: f32,

    fov: f32,
    near: f32,
    far: f32,

    /// internal use only
    pos: vec3,

    pub fn init(target: vec3, dist: f32, fov: f32, near: f32, far: f32) ArcBall {
        var self = ArcBall{
            .target = target,
            .dist = dist,
            .horizontal_angle = 0,
            .vertical_angle = 45,
            .fov = fov,
            .near = near,
            .far = far,
            .pos = undefined,
        };
        self.update(target, math.zeroes(vec2));
        return self;
    }

    pub fn update(self: *ArcBall, target: vec3, mouse_diff: vec2) void {
        self.target = target;

        const ang_speed = 3.5;
        self.horizontal_angle += ang_speed * -mouse_diff[0];
        self.vertical_angle += ang_speed * mouse_diff[1];

        self.horizontal_angle = @mod(self.horizontal_angle, 360);
        self.vertical_angle = std.math.clamp(self.vertical_angle, -80, 80);

        // note: horizontal angle is 0 at -z, goes around +y (right hand rule)
        const y = self.dist * @sin(math.to_radians(self.vertical_angle));
        const plane_dist = self.dist * @cos(math.to_radians(self.vertical_angle));
        const z = -(plane_dist * @cos(math.to_radians(self.horizontal_angle)));
        const x = -(plane_dist * @sin(math.to_radians(self.horizontal_angle)));

        self.pos = self.target + vec3{ x, y, z };
    }

    pub fn set_matrices(self: ArcBall, shader: gfx.Shader, screen_ratio: f32) void {
        const yaw = (self.horizontal_angle + 180);
        const pitch = -self.vertical_angle;

        const view_mat = math.view(self.pos, yaw, pitch);
        shader.set("v", view_mat);
        const proj_mat = math.projection(self.fov, screen_ratio, self.near, self.far);
        shader.set("p", proj_mat);
    }

    pub fn look_dir(self: ArcBall) vec3 {
        return math.normalize(self.target - self.pos);
    }

    pub fn right_dir(self: ArcBall) vec3 {
        return math.cross(self.look_dir(), math.axis_vec(.y));
    }
};

pub const FPCam = struct {
    pos: vec3,
    /// yaw and pitch are in degrees
    yaw: f32 = 0,
    pitch: f32 = 0,

    fov: f32,
    near: f32,
    far: f32,

    pub fn update(self: *FPCam, pos: vec3, mouse_diff: vec2) void {
        self.pos = pos;
        const sensitivity = 0.1;
        self.yaw += sensitivity * -mouse_diff[0];
        self.pitch += sensitivity * -mouse_diff[1];
    }

    pub fn set_matrices(self: FPCam, shader: gfx.Shader, screen_ratio: f32) void {
        shader.set("v", math.view(self.pos, self.yaw, self.pitch));
        shader.set("p", math.projection(self.fov, screen_ratio, self.near, self.far));
    }

    pub fn look_dir(self: FPCam) vec3 {
        return math.normalize(vec3{
            -@sin(math.to_radians(self.yaw)),
            @sin(math.to_radians(self.pitch)),
            -@cos(math.to_radians(self.yaw)),
        });
    }
};

pub const FreeCam = struct {
    pos: vec3,
    yaw: f32,
    pitch: f32,
    fov: f32,
    near: f32,
    far: f32,

    pub fn get_proj_mat(self: FreeCam, screen_ratio: f32) mat4 {
        return math.projection(self.fov, screen_ratio, self.near, self.far);
    }

    pub fn get_view_mat(self: FreeCam) mat4 {
        return math.view(self.pos, self.yaw, self.pitch);
    }

    pub fn set_matrices(self: FreeCam, shader: gfx.Shader, screen_ratio: f32) void {
        const view_mat = self.get_view_mat();
        shader.set("v", view_mat);
        const proj_mat = self.get_proj_mat(screen_ratio);
        shader.set("p", proj_mat);
    }

    pub fn look_dir(self: FreeCam) vec3 {
        const y = @sin(math.to_radians(self.pitch));
        const xz_plane_len = @cos(math.to_radians(self.pitch));

        const x = xz_plane_len * -@sin(math.to_radians(self.yaw));
        const z = xz_plane_len * -@cos(math.to_radians(self.yaw));

        const dir_vec = vec3{ x, y, z };
        return math.normalize(dir_vec);
    }

    pub fn right_dir(self: FreeCam) vec3 {
        const angle = @mod(self.yaw - 90, 360);
        const x = -@sin(math.to_radians(angle));
        const z = -@cos(math.to_radians(angle));

        const dir_vec = vec3{ x, 0, z };
        return math.normalize(dir_vec);
    }

    // TODO
    //pub fn point_at(self: *FreeCam, target: vec3) void {
    //    const look_dir = math.normalize(target - self.pos);
    //}

    pub fn update_angles(self: *FreeCam, mouse_diff: vec2) void {
        const cam_scalar = 0.20;
        self.yaw = @mod(self.yaw - cam_scalar * mouse_diff[0], 360);
        self.pitch = std.math.clamp(self.pitch + cam_scalar * -mouse_diff[1], -89, 89);
    }

    pub fn update_pos(self: *FreeCam, forward: f32, right: f32, up: f32) void {
        const foward_vec = self.look_dir();
        const right_vec = self.right_dir();
        const move_dir = math.times(foward_vec, forward) + math.times(right_vec, right);

        const move_vec = math.normalize(move_dir) + math.times(math.axis_vec(.y), up);

        const move_speed = 0.3;
        self.pos += math.times(move_vec, move_speed);
    }
};
