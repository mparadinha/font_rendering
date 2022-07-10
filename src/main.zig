const std = @import("std");
const Allocator = std.mem.Allocator;

const gl = @import("gl_4v3.zig");
const c = @import("c.zig").c;

const Window = @import("window.zig").Window;
const gfx = @import("graphics.zig");
const math = @import("math.zig");
const vec2 = math.vec2;
const vec3 = math.vec3;
const vec4 = math.vec4;
const mat4 = math.mat4;
const camera = @import("camera.zig");

pub fn main() anyerror!void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{
        .stack_trace_frames = 8,
        .enable_memory_limit = true,
    }){};
    defer _ = general_purpose_allocator.detectLeaks();
    const gpa = general_purpose_allocator.allocator();

    const font = @import("font.zig");
    const glyf = try font.loadTTF(gpa, "VictorMono-Regular.ttf");
    defer glyf.free(gpa);
    //if (true) return;

    var width: u32 = 800;
    var height: u32 = 800;

    // setup GLFW
    var window = Window.init(gpa, width, height, "font rendering");
    window.setup_callbacks();
    defer window.deinit();
    // setup OpenGL
    try gl.load(window.handle, get_proc_address_fn);
    gl.enable(gl.DEBUG_OUTPUT);
    gl.debugMessageCallback(gl_error_callback, null);
    std.log.info("{s}", .{gl.getString(gl.VERSION)});

    // GL state that we never change
    gl.clearColor(1, 0.9, 0.8, 1);
    gl.enable(gl.CULL_FACE);
    gl.enable(gl.BLEND);
    gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
    gl.enable(gl.DEPTH_TEST);
    gl.depthFunc(gl.LEQUAL);
    gl.enable(gl.LINE_SMOOTH);

    // things we keep track of to the next frame
    var last_time = @floatCast(f32, c.glfwGetTime());
    var frame_num: u64 = 0;
    var frame_times = [_]f32{0} ** 100;

    var font_shader = gfx.Shader.from_files(gpa, "font_shader");
    defer font_shader.deinit();
    // zig fmt: off
    const quad_data = [_]f32{
        -0.5, -0.5,   0, 0,
         0.5, -0.5,   1, 0,
         0.5,  0.5,   1, 1,
        -0.5,  0.5,   0, 1,
    };
    // zig fmt: on
    const quad_indices = [_]u32{ 0, 1, 2, 0, 2, 3 };
    var quad_text_mesh = gfx.Mesh.init(&quad_data, &quad_indices, &.{
        .{ .n_elems = 2 },
        .{ .n_elems = 2 },
    });
    defer quad_text_mesh.deinit();
    var glyf_tex_data = std.ArrayList(i16).init(gpa);
    defer glyf_tex_data.deinit();
    for (glyf.contours) |cnt| {
        try glyf_tex_data.append(@intCast(i16, cnt.segments.len));
        for (cnt.segments) |s| {
            switch (s) {
                .line => |line| {
                    try glyf_tex_data.append(0);
                    try glyf_tex_data.append(line.start_point.x);
                    try glyf_tex_data.append(line.start_point.y);
                    try glyf_tex_data.append(line.end_point.x);
                    try glyf_tex_data.append(line.end_point.y);
                },
                .curve => |curve| {
                    try glyf_tex_data.append(1);
                    try glyf_tex_data.append(curve.start_point.x);
                    try glyf_tex_data.append(curve.start_point.y);
                    try glyf_tex_data.append(curve.control_point.x);
                    try glyf_tex_data.append(curve.control_point.y);
                    try glyf_tex_data.append(curve.end_point.x);
                    try glyf_tex_data.append(curve.end_point.y);
                },
            }
        }
    }
    //const texture_data = [10]i16{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    //const texture = dataTexture(&texture_data);
    const texture = dataTexture(glyf_tex_data.items);

    var zoom_mult: f32 = 1;
    var panning_view = false;
    var cumm_offset = math.zeroes(vec2);
    var pan_offset = math.zeroes(vec2);
    var pan_start_pos = math.zeroes(vec2);

    while (!window.should_close()) {
        frame_num += 1;

        var event = window.event_queue.next();
        while (event) |ev| : (event = window.event_queue.next()) {
            var remove = true;
            switch (ev) {
                .MouseDown => {
                    panning_view = true;
                    pan_start_pos = pan_offset + window.mouse_pos_ndc();
                },
                .MouseUp => {
                    panning_view = false;
                    cumm_offset += pan_offset;
                    pan_offset = math.zeroes(vec2);
                },
                .MouseScroll => |scroll| zoom_mult += scroll.y / 10,
                else => remove = false,
            }
            if (remove) window.event_queue.removeCurrent();
        }
        if (panning_view) pan_offset = window.mouse_pos_ndc() - pan_start_pos;

        window.framebuffer_size(&width, &height);
        gl.viewport(0, 0, @intCast(i32, width), @intCast(i32, height));
        const ratio = @intToFloat(f32, width) / @intToFloat(f32, height);
        _ = ratio;

        const cur_time = @floatCast(f32, c.glfwGetTime());
        const dt = cur_time - last_time;
        last_time = cur_time;
        _ = dt;
        frame_times[frame_num % frame_times.len] = dt;

        // start rendering
        gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

        font_shader.bind();
        font_shader.set("zoom_mult", zoom_mult);
        font_shader.set("pan_offset", cumm_offset + pan_offset);
        font_shader.set("xmin", @intCast(i32, glyf.xmin));
        font_shader.set("ymin", @intCast(i32, glyf.ymin));
        font_shader.set("xmax", @intCast(i32, glyf.xmax));
        font_shader.set("ymax", @intCast(i32, glyf.ymax));
        font_shader.set("n_contours", @intCast(u32, glyf.contours.len));
        font_shader.set("texture_data", @as(i32, 0));
        texture.bind(0);
        quad_text_mesh.draw();

        window.update();
    }
}

fn dataTexture(data: []const i16) gfx.Texture {
    std.debug.print("data texture for data.len={}\n", .{data.len});
    var id: u32 = undefined;
    gl.genTextures(1, &id);
    gl.bindTexture(gl.TEXTURE_1D, id);
    gl.texParameteri(gl.TEXTURE_1D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_1D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    // zig fmt: off
    gl.texImage1D(
        gl.TEXTURE_1D, 0, gl.R16I,
        @intCast(i32, data.len), 0,
        gl.RED_INTEGER, gl.SHORT,
        @ptrCast(*const anyopaque, data.ptr),
    );
    // zig fmt: on
    return gfx.Texture{
        .id = id,
        .width = @intCast(u32, data.len),
        .height = 1,
        .tex_type = gl.TEXTURE_1D,
    };
}

fn get_proc_address_fn(window: ?*c.GLFWwindow, proc_name: [:0]const u8) ?*const anyopaque {
    _ = window;
    const fn_ptr = c.glfwGetProcAddress(proc_name);
    // without this I got a "cast discards const qualifier" error
    return @intToPtr(?*opaque {}, @ptrToInt(fn_ptr));
}

fn gl_error_callback(source: u32, error_type: u32, id: u32, severity: u32, len: i32, msg: [*:0]const u8, user_param: ?*const anyopaque) callconv(.C) void {
    _ = len;
    _ = user_param;

    if (severity == gl.DEBUG_SEVERITY_NOTIFICATION) return;

    const source_str = switch (source) {
        0x824B => "SOURCE_OTHER",
        0x824A => "SOURCE_APPLICATION",
        0x8249 => "SOURCE_THIRD_PARTY",
        0x8248 => "SOURCE_SHADER_COMPILER",
        0x8247 => "SOURCE_WINDOW_SYSTEM",
        0x8246 => "SOURCE_API",
        else => unreachable,
    };
    const error_type_str = switch (error_type) {
        0x826A => "TYPE_POP_GROUP",
        0x8269 => "TYPE_PUSH_GROUP",
        0x8268 => "TYPE_MARKER",
        0x8251 => "TYPE_OTHER",
        0x8250 => "TYPE_PERFORMANCE",
        0x824F => "TYPE_PORTABILITY",
        0x824E => "TYPE_UNDEFINED_BEHAVIOR",
        0x824D => "TYPE_DEPRECATED_BEHAVIOR",
        0x824C => "TYPE_ERROR",
        else => unreachable,
    };
    const severity_str = switch (severity) {
        0x826B => "SEVERITY_NOTIFICATION",
        0x9148 => "SEVERITY_LOW",
        0x9147 => "SEVERITY_MEDIUM",
        0x9146 => "SEVERITY_HIGH",
        else => unreachable,
    };
    std.log.info("OpenGL: ({s}, {s}, {s}, id={}) {s}", .{ source_str, severity_str, error_type_str, id, msg });
}
