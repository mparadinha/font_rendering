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

    //const font = @import("font.zig");
    //const glyph = try font.loadTTF(gpa, "VictorMono-Regular.ttf");
    //defer glyph.free(gpa);

    const font_v2 = try @import("font_v2.zig").init(gpa, "VictorMono-Regular.ttf");
    defer font_v2.deinit(gpa);
    //for (font_v2.curve_points) |pt| std.debug.print("({: >5}, {: >5})\n", .{ pt.x, pt.y });
    //for (font_v2.glyphs) |g| std.debug.print("pt off={}, n_pts={}\n", .{ g.points_offset, g.n_points });
    const g_idx = 0;
    const g = font_v2.glyphs[g_idx];
    std.debug.print("points for glyph #{}\n", .{g_idx});
    for (font_v2.curve_points[g.points_offset .. g.points_offset + g.n_points]) |pt, i| {
        std.debug.print("#{}: ({: >5}, {: >5})\n", .{ i, pt.x, pt.y });
    }
    std.debug.print("points_offset={}\n", .{g.points_offset});
    std.debug.print("n_points={}\n", .{g.n_points});
    std.debug.print("contour_n_curves={d}\n", .{g.contour_n_curves});
    //if (true) return;

    var width: u32 = 900;
    var height: u32 = 900;

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
    gl.clearColor(1, 0.6, 0.8, 1);
    //gl.clearColor(0, 0, 0, 0);
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

    var font_shader = gfx.Shader.from_files(gpa, "font_v2");
    defer font_shader.deinit();
    var data_buf: []i16 = undefined;
    data_buf.ptr = @ptrCast([*]i16, font_v2.curve_points.ptr);
    data_buf.len = font_v2.curve_points.len * 2;
    const point_data_texture = try dataTexture(i16, gpa, data_buf);
    var glyph_data_buf = std.ArrayList(u16).init(gpa);
    defer glyph_data_buf.deinit();
    var glyph_data_start = std.ArrayList(usize).init(gpa);
    defer glyph_data_start.deinit();
    for (font_v2.glyphs) |glyph| {
        try glyph_data_start.append(glyph_data_buf.items.len);

        try glyph_data_buf.append(@intCast(u16, glyph.points_offset));
        try glyph_data_buf.append(@intCast(u16, glyph.contour_n_curves.len));
        for (glyph.contour_n_curves) |n_curves| try glyph_data_buf.append(n_curves);
    }
    const glyph_data_texture = try dataTexture(u16, gpa, glyph_data_buf.items);
    var quad_data = std.ArrayList(f32).init(gpa);
    defer quad_data.deinit();
    var quad_indices = std.ArrayList(u32).init(gpa);
    defer quad_indices.deinit();
    var x: f32 = 0;
    var y: f32 = 0;
    for (font_v2.glyphs) |glyph, i| {
        const base_indices = [_]u32{ 0, 1, 2, 0, 2, 3 };
        for (base_indices) |idx| try quad_indices.append(idx + @intCast(u32, i) * 4);
        const data_start = @intToFloat(f32, glyph_data_start.items[i]);
        // zig fmt: off
        try quad_data.appendSlice(&[_]f32{
            x    , y    , @intToFloat(f32, glyph.xmin), @intToFloat(f32, glyph.ymin), data_start,
            x + 1, y    , @intToFloat(f32, glyph.xmax), @intToFloat(f32, glyph.ymin), data_start,
            x + 1, y + 1, @intToFloat(f32, glyph.xmax), @intToFloat(f32, glyph.ymax), data_start,
            x    , y + 1, @intToFloat(f32, glyph.xmin), @intToFloat(f32, glyph.ymax), data_start,
        });
        // zig fmt: on
        x += 1;
        if (x >= 20) {
            x = 0;
            y += 1;
        }
    }
    var quad_text_mesh = gfx.Mesh.init(quad_data.items, quad_indices.items, &.{
        .{ .n_elems = 2 },
        .{ .n_elems = 2 },
        .{ .n_elems = 1 },
    });
    defer quad_text_mesh.deinit();
    const outline_shader = gfx.Shader.from_srcs(gpa, "outline", .{
        .vertex = 
        \\#version 330 core
        \\layout (location = 0) in vec2 pos;
        \\uniform float zoom_mult;
        \\uniform vec2 pan_offset;
        \\void main() { gl_Position = vec4((zoom_mult * pos) + pan_offset, 0, 1); }
        \\
        ,
        .fragment = 
        \\#version 330 core
        \\out vec4 FragColor;
        \\void main() { FragColor = vec4(1); }
        \\
        ,
    });
    defer outline_shader.deinit();

    var zoom_mult: f32 = 2;
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
                .MouseScroll => |scroll| {
                    const increase_mult = 1 + scroll.y * 0.25;
                    cumm_offset = math.times(cumm_offset, increase_mult);
                    zoom_mult *= increase_mult;
                },
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
        font_shader.set("curve_point_data_tex", @as(i32, 0));
        point_data_texture.bind(0);
        font_shader.set("glyph_data_tex", @as(i32, 1));
        glyph_data_texture.bind(1);
        quad_text_mesh.draw();

        outline_shader.bind();
        outline_shader.set("zoom_mult", zoom_mult);
        outline_shader.set("pan_offset", cumm_offset + pan_offset);
        gl.polygonMode(gl.FRONT_AND_BACK, gl.LINE);
        quad_text_mesh.draw();
        gl.polygonMode(gl.FRONT_AND_BACK, gl.FILL);

        window.update();
    }
}

fn dataTexture(comptime T: type, allocator: Allocator, data: []const T) !gfx.Texture {
    std.debug.print("data texture for data.len={}\n", .{data.len});
    var max_texture_size: i32 = undefined;
    gl.getIntegerv(gl.MAX_TEXTURE_SIZE, &max_texture_size);
    std.debug.print("GL_MAX_TEXTURE_SIZE = {}\n", .{max_texture_size});

    const width = @intCast(u32, max_texture_size);
    const height = @divTrunc(@intCast(u32, data.len), width) + 1;
    std.debug.print("texture dim: ({}, {})\n", .{ width, height });

    var buf = try allocator.alloc(T, width * height);
    defer allocator.free(buf);
    std.mem.copy(T, buf, data);

    const internal_format = switch (T) {
        u16 => gl.R16UI,
        i16 => gl.R16I,
        else => unreachable,
    };
    const data_format = switch (T) {
        u16, i16 => gl.RED_INTEGER,
        else => unreachable,
    };
    const data_type = switch (T) {
        u16 => gl.UNSIGNED_SHORT,
        i16 => gl.SHORT,
        else => unreachable,
    };

    // zig fmt: off
    return gfx.Texture.initOptions(
        width, height, internal_format,
        data_format, @ptrCast([*]const u8, buf.ptr), data_type,
        gl.TEXTURE_2D, false,
        &.{
            .{ .name = gl.TEXTURE_MIN_FILTER, .value = gl.NEAREST },
            .{ .name = gl.TEXTURE_MAG_FILTER, .value = gl.NEAREST },
        },
    );
    // zig fmt: on
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
