const std = @import("std");
const Allocator = std.mem.Allocator;

pub const LoadError = error{
    NotOpenType,
    NoCmapTable,
    NoGlyphTable,
    NoLocaTable,
    NoHeadTable,
    NoMaxpTable,
};

pub const Glyph = struct {
    contours: []Contour,
    xmin: i16,
    ymin: i16,
    xmax: i16,
    ymax: i16,

    pub const Contour = struct {
        segments: []Segment,
    };

    pub const Segment = union(enum) {
        curve: struct {
            start_point: Point,
            control_point: Point,
            end_point: Point,
        },
        line: struct {
            start_point: Point,
            end_point: Point,
        },
    };

    pub const Point = struct {
        x: i16,
        y: i16,

        pub fn format(value: Point, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            _ = options;
            try std.fmt.format(writer, "({" ++ fmt ++ "}, {" ++ fmt ++ "})", .{ value.x, value.y });
        }
    };

    pub fn free(self: Glyph, allocator: Allocator) void {
        for (self.contours) |contour| allocator.free(contour.segments);
        allocator.free(self.contours);
    }
};

/// Caller owns returned memory. Call glyph.free(allocator) to clean up.
fn decodeGlyph(allocator: Allocator, data: []u8) !Glyph {
    const reader = std.io.fixedBufferStream(data).reader();

    var glyph: Glyph = undefined;

    const num_contours = try reader.readIntBig(i16);
    if (num_contours < 0) {
        std.debug.print("ignoring compound contours for now\n", .{});
        return glyph;
    }
    glyph.contours = try allocator.alloc(Glyph.Contour, @intCast(usize, num_contours));

    glyph.xmin = try reader.readIntBig(i16);
    glyph.ymin = try reader.readIntBig(i16);
    glyph.xmax = try reader.readIntBig(i16);
    glyph.ymax = try reader.readIntBig(i16);

    // TODO: compound glyphs
    std.debug.assert(num_contours >= 0);

    var end_points = try allocator.alloc(u16, @intCast(usize, num_contours));
    defer allocator.free(end_points);
    for (end_points) |*end_point| end_point.* = try reader.readIntBig(u16);

    const total_points = end_points[end_points.len - 1] + 1;

    const instructions_len = try reader.readIntBig(u16);
    try reader.skipBytes(instructions_len, .{});

    var point_flags = try allocator.alloc(u8, total_points);
    defer allocator.free(point_flags);
    var x_coords = try allocator.alloc(i16, total_points);
    defer allocator.free(x_coords);
    var y_coords = try allocator.alloc(i16, total_points);
    defer allocator.free(y_coords);
    // read flags
    var flags_done: usize = 0;
    while (flags_done < total_points) {
        const flags = try reader.readByte();
        point_flags[flags_done] = flags;
        flags_done += 1;
        if ((flags & 0x08) != 0) {
            const repeat = try reader.readByte();
            var done: usize = 0;
            while (done < repeat) : (done += 1) {
                point_flags[flags_done] = flags;
                flags_done += 1;
            }
        }
    }
    // read x coords
    for (x_coords) |*x, i| {
        const flags = point_flags[i];
        const short_flag = (flags & 0x02) != 0;
        const same_flag = (flags & 0x10) != 0;
        const last_x = if (i == 0) 0 else x_coords[i - 1];
        const delta = if (short_flag) blk: {
            const value = @bitCast(i16, @intCast(u16, try reader.readByte()));
            break :blk if (same_flag) value else -value;
        } else blk: {
            if (same_flag) break :blk 0;
            break :blk try reader.readIntBig(i16);
        };
        x.* = last_x + delta;
    }
    // read y coords
    for (y_coords) |*y, i| {
        const flags = point_flags[i];
        const short_flag = (flags & 0x04) != 0;
        const same_flag = (flags & 0x20) != 0;
        const last_y = if (i == 0) 0 else y_coords[i - 1];
        const delta = if (short_flag) blk: {
            const value = @bitCast(i16, @intCast(u16, try reader.readByte()));
            break :blk if (same_flag) value else -value;
        } else blk: {
            if (same_flag) break :blk 0;
            break :blk try reader.readIntBig(i16);
        };
        std.debug.print("delta={}\n", .{delta});
        y.* = last_y + delta;
    }

    // TODO: explain the thing
    // NOTE: when two quadratic curves are consecutive and share an on-curve control point
    // sometimes that shared point is omitted.
    // so instead of storing this:
    // https://developer.apple.com/fonts/TrueType-Reference-Manual/RM01/fig02.jpg
    // the fonts just stores this:
    // https://developer.apple.com/fonts/TrueType-Reference-Manual/RM01/fig03.jpg
    // and we can just get the middle point by doing an average
    const Point = struct { x: i16, y: i16, on_curve: bool };
    var points_list = try std.ArrayList(Point).initCapacity(allocator, total_points);
    var new_end_points = try allocator.alloc(u16, @intCast(usize, num_contours));
    defer allocator.free(new_end_points);
    for (end_points) |end_point_idx, i| {
        const start_point_idx = if (i == 0) 0 else end_points[i - 1] + 1;
        for (point_flags[start_point_idx .. end_point_idx + 1]) |flag, j| {
            const idx = j + start_point_idx;
            const point = Point{
                .x = x_coords[idx],
                .y = y_coords[idx],
                .on_curve = (flag & 0x01) != 0,
            };
            try points_list.append(point);
            const next_idx = if (idx == end_point_idx) start_point_idx else idx + 1;
            const next_on_curve = (point_flags[next_idx] & 0x01) != 0;
            if (!point.on_curve and !next_on_curve) {
                const omitted_control_point = Point{
                    .x = @divTrunc(x_coords[next_idx] + point.x, 2),
                    .y = @divTrunc(y_coords[next_idx] + point.y, 2),
                    .on_curve = true,
                };
                try points_list.append(omitted_control_point);
            }
        }
        new_end_points[i] = @intCast(u16, points_list.items.len) - 1;
    }
    const points = points_list.toOwnedSlice();
    defer allocator.free(points);

    std.debug.print("all points (omitted control ones re-generated):\n", .{});
    for (points) |pt, i| {
        std.debug.print("[{:>2}] :: x={: >5}, y={: >5}, on_curve={}\n", .{ i, pt.x, pt.y, pt.on_curve });
    }

    // convert points into lists of segments
    for (glyph.contours) |*contour, contour_idx| {
        var segments = std.ArrayList(Glyph.Segment).init(allocator);

        const start_point_idx = if (contour_idx == 0) 0 else new_end_points[contour_idx - 1] + 1;
        const contour_points = new_end_points[contour_idx] - start_point_idx + 1;

        var point_idx: usize = start_point_idx;
        while (point_idx <= new_end_points[contour_idx]) {
            std.debug.print("contour={}, point_idx={}\n", .{ contour_idx, point_idx });

            const point = points[point_idx];

            // sometimes a contour will start in the middle of a curve
            // we'll get this segment at the end of the contour when it wraps
            if (!point.on_curve) {
                point_idx += 1;
                continue;
            }

            const next_idx = (((point_idx + 1) - start_point_idx) % contour_points) + start_point_idx;
            const next_point = points[next_idx];

            // two consecutive points on_curve means line segment
            if (next_point.on_curve) {
                try segments.append(.{ .line = .{
                    .start_point = .{ .x = point.x, .y = point.y },
                    .end_point = .{ .x = next_point.x, .y = next_point.y },
                } });
                point_idx += 1;
                continue;
            }

            const next_next_idx = (((point_idx + 2) - start_point_idx) % contour_points) + start_point_idx;
            const next_next_point = points[next_next_idx];
            std.debug.assert(next_next_point.on_curve);

            try segments.append(.{ .curve = .{
                .start_point = .{ .x = point.x, .y = point.y },
                .control_point = .{ .x = next_point.x, .y = next_point.y },
                .end_point = .{ .x = next_next_point.x, .y = next_next_point.y },
            } });
            point_idx += 2;
        }

        contour.segments = segments.toOwnedSlice();
    }

    return glyph;
}

pub fn loadTTF(allocator: Allocator, filepath: []const u8) !Glyph {
    const ttf_data = try std.fs.cwd().readFileAlloc(allocator, filepath, std.math.maxInt(usize));
    defer allocator.free(ttf_data);

    std.debug.print("ttf_data is {} bytes\n", .{ttf_data.len});

    const open_type_sig = [4]u8{ 0, 1, 0, 0 };
    if (!std.mem.eql(u8, ttf_data[0..4], &open_type_sig)) return LoadError.NotOpenType;

    const num_tables = std.mem.readIntSliceBig(u16, ttf_data[4..6]);
    std.debug.print("num_tables = {}\n", .{num_tables});

    var cmap_loc: ?usize = null;
    var glyf_loc: ?usize = null;
    var loca_loc: ?usize = null;
    var head_loc: ?usize = null;
    var maxp_loc: ?usize = null;

    var i: usize = 0;
    while (i < num_tables) : (i += 1) {
        const table_loc = 12 + 16 * i;
        const tag = ttf_data[table_loc .. table_loc + 4];
        const filepos = std.mem.readIntSliceBig(u32, ttf_data[table_loc + 8 .. table_loc + 8 + 4]);
        std.debug.print("tag: {s}, (@ 0x{x})\n", .{ tag, filepos });

        if (std.mem.eql(u8, tag, "cmap")) cmap_loc = filepos;
        if (std.mem.eql(u8, tag, "glyf")) glyf_loc = filepos;
        if (std.mem.eql(u8, tag, "loca")) loca_loc = filepos;
        if (std.mem.eql(u8, tag, "head")) head_loc = filepos;
        if (std.mem.eql(u8, tag, "maxp")) maxp_loc = filepos;
    }

    const num_glyphs = if (maxp_loc) |loc| std.mem.readIntSliceBig(u16, ttf_data[loc + 4 .. loc + 6]) else return LoadError.NoMaxpTable;
    std.debug.print("num_glyphs = {}\n", .{num_glyphs});

    var index_to_loc_format: usize = undefined;

    if (head_loc) |loc| {
        std.debug.print("'head' table:\n", .{});
        index_to_loc_format = std.mem.readIntSliceBig(u16, ttf_data[loc + 50 .. loc + 52]);
        std.debug.print("indexToLocFormat = {}\n", .{index_to_loc_format});
    } else return LoadError.NoHeadTable;

    var glyph_locs = std.ArrayList(struct { offset: usize, size: usize }).init(allocator);
    defer glyph_locs.deinit();

    if (loca_loc) |loc| {
        std.debug.print("'loca' table:\n", .{});
        i = 0;
        const loca_offsets_size: usize = if (index_to_loc_format == 1) 4 else 2;
        while (i < num_glyphs + 1) : (i += 1) {
            const loc_offset = loc + loca_offsets_size * i;
            const glyph_offset_data = ttf_data[loc_offset .. loc_offset + loca_offsets_size];
            const glyph_offset = switch (loca_offsets_size) {
                2 => @intCast(u32, std.mem.readIntSliceBig(u16, glyph_offset_data)),
                4 => std.mem.readIntSliceBig(u32, glyph_offset_data),
                else => unreachable,
            } * if (index_to_loc_format == 1) @as(usize, 1) else @as(usize, 2);

            if (i > 0 and i < num_glyphs) {
                const last_offset = glyph_locs.items[glyph_locs.items.len - 1].offset;
                glyph_locs.items[glyph_locs.items.len - 1].size = glyph_offset - last_offset;
            }

            try glyph_locs.append(.{ .offset = glyph_offset, .size = 0 });
        }
    } else return LoadError.NoLocaTable;

    //for (glyph_locs.items) |loc, idx| std.debug.print("glyph #{: >4}: offset={: >5}, size={: >4}\n", .{ idx, loc.offset, loc.size });

    var g: Glyph = undefined;

    //if (glyf_loc) |loc| {
    //    var compound_glyphs: usize = 0;
    //    for (glyph_locs.items) |glyph, glyph_idx| {
    //        std.debug.print("glyph #{}: offset={}, size={}\n", .{ glyph_idx, glyph.offset, glyph.size });
    //        if (glyph.size == 0) continue;

    //        const glyph_data = ttf_data[loc + glyph.offset .. loc + glyph.offset + glyph.size];
    //        var glyph_stream = std.io.fixedBufferStream(glyph_data);
    //        const glyph_reader = glyph_stream.reader();

    //        const num_contours = try glyph_reader.readIntBig(i16);
    //        std.debug.print("  # of contours: {}\n", .{num_contours});
    //        const xmin = try glyph_reader.readIntBig(i16);
    //        const ymin = try glyph_reader.readIntBig(i16);
    //        const xmax = try glyph_reader.readIntBig(i16);
    //        const ymax = try glyph_reader.readIntBig(i16);
    //        std.debug.print("  xmin: {}, ymin: {} (FUnits)\n", .{ xmin, ymin });
    //        std.debug.print("  xmax: {}, ymax: {} (FUnits)\n", .{ xmax, ymax });

    //        // TODO: deal with compound glyphs
    //        //std.debug.assert(num_contours >= 0);
    //        if (num_contours < 0) {
    //            std.debug.print("  glyph idx={} is compound!\n", .{glyph_idx});
    //            compound_glyphs += 1;

    //            var done = false;
    //            var has_instructions = false;
    //            while (!done) {
    //                const comp_flags = try glyph_reader.readIntBig(u16);
    //                const comp_glyph_idx = try glyph_reader.readIntBig(u16);
    //                std.debug.print("  flags = 0x{x:0>4}\n", .{comp_flags});
    //                std.debug.print("  glyphIndex = {}\n", .{comp_glyph_idx});

    //                const args_are_words = (comp_flags & 0x0001) != 0;
    //                const args_are_values = (comp_flags & 0x0002) != 0;
    //                const simple_scale = (comp_flags & 0x0008) != 0;
    //                const more_comps = (comp_flags & 0x0020) != 0;
    //                const xy_scale = (comp_flags & 0x0040) != 0;
    //                const two_by_two_scale = (comp_flags & 0x0080) != 0;
    //                const have_instructions = (comp_flags & 0x0100) != 0;
    //                //const use_metrics = (comp_flags & 0x0200) != 0;
    //                //const overlap_compound = (comp_flags & 0x0400) != 0;

    //                std.debug.print("  args_are_words = {}\n", .{args_are_words});
    //                std.debug.print("  args_are_values = {}\n", .{args_are_values});
    //                std.debug.print("  simple_scale = {}\n", .{simple_scale});
    //                std.debug.print("  more_comps = {}\n", .{more_comps});
    //                std.debug.print("  xy_scale = {}\n", .{xy_scale});
    //                std.debug.print("  two_by_two_scale = {}\n", .{two_by_two_scale});
    //                std.debug.print("  have_instructions = {}\n", .{have_instructions});
    //                //std.debug.print("  use_metrics = {}\n", .{use_metrics});
    //                //std.debug.print("  overlap_compound = {}\n", .{overlap_compound});

    //                if (args_are_words) {
    //                    if (args_are_values) {
    //                        const arg1 = glyph_reader.readIntBig(i16);
    //                        const arg2 = glyph_reader.readIntBig(i16);
    //                        std.debug.print("  arg1={}, arg2={}\n", .{ arg1, arg2 });
    //                    } else {
    //                        const arg1 = glyph_reader.readIntBig(u16);
    //                        const arg2 = glyph_reader.readIntBig(u16);
    //                        std.debug.print("  arg1={}, arg2={}\n", .{ arg1, arg2 });
    //                    }
    //                } else {
    //                    if (args_are_values) {
    //                        const arg1 = glyph_reader.readIntBig(i8);
    //                        const arg2 = glyph_reader.readIntBig(i8);
    //                        std.debug.print("  arg1={}, arg2={}\n", .{ arg1, arg2 });
    //                    } else {
    //                        const arg1 = glyph_reader.readIntBig(u8);
    //                        const arg2 = glyph_reader.readIntBig(u8);
    //                        std.debug.print("  arg1={}, arg2={}\n", .{ arg1, arg2 });
    //                    }
    //                }

    //                if (simple_scale) {
    //                    const scale = glyph_reader.readIntBig(i16);
    //                    std.debug.print("  simple scale = {}\n", .{scale});
    //                } else if (xy_scale) {
    //                    const xscale = glyph_reader.readIntBig(u16);
    //                    const yscale = glyph_reader.readIntBig(u16);
    //                    std.debug.print("  xy scale = (0x{x:0>4}, 0x{x:0>4})\n", .{ xscale, yscale });
    //                } else if (two_by_two_scale) {
    //                    const xscale = glyph_reader.readIntBig(u16);
    //                    const scale01 = glyph_reader.readIntBig(u16);
    //                    const scale10 = glyph_reader.readIntBig(u16);
    //                    const yscale = glyph_reader.readIntBig(u16);
    //                    std.debug.print("  2x2 scale: x=0x{x:0>4}, 01=0x{x:0>4}, 10=0x{x:0>4}, y=0x{x:0>4}\n", .{ xscale, scale01, scale10, yscale });
    //                } else {
    //                    std.debug.print("  scale = 1.0 (no scale information present)\n", .{});
    //                }

    //                // transformation parameters
    //                //const m: f32 = 0;
    //                //const n: f32 = 0;
    //                //const a: f32 = 0;
    //                //const b: f32 = 0;
    //                //const c: f32 = 0;
    //                //const d: f32 = 0;
    //                //const e: f32 = 0;
    //                //const f: f32 = 0;

    //                if (!more_comps) {
    //                    done = true;
    //                    has_instructions = have_instructions;
    //                }
    //            }

    //            if (has_instructions) {
    //                const n_instrs = try glyph_reader.readIntBig(u16);
    //                try glyph_reader.skipBytes(n_instrs, .{});
    //            }

    //            continue;
    //        }

    //        var total_num_points: u16 = 0;

    //        std.debug.print("  end pts of contours: [", .{});
    //        var contour: usize = 0;
    //        while (contour < num_contours) : (contour += 1) {
    //            const end_pt = try glyph_reader.readIntBig(u16);
    //            const str = if (contour == num_contours - 1) "]\n" else ", ";
    //            std.debug.print("{}{s}", .{ end_pt, str });
    //            // TODO: report this bug to zig compiler repo (might be fixed in stage2):
    //            // this prints the "]\n" twice:
    //            //std.debug.print("{}{s}", .{ end_pt, if (contour == num_contours - 1) "]\n" else ", " });
    //            // but if we put it in a variable it works:
    //            //const str = if (contour == num_contours - 1) "]\n" else ", ";
    //            //std.debug.print("{}{s}", .{ end_pt, str });

    //            if (contour == num_contours - 1) total_num_points = end_pt + 1;
    //        }

    //        const instructions_len = try glyph_reader.readIntBig(u16);
    //        std.debug.print("  instructions: [", .{});
    //        var insts: usize = 0;
    //        while (insts < instructions_len) : (insts += 1) {
    //            const inst = try glyph_reader.readByte();
    //            const str = if (insts == instructions_len - 1) "]\n" else ", ";
    //            std.debug.print("0x{x:0>2}{s}", .{ inst, str });
    //        }

    //        std.debug.print("  # of points: {}\n", .{total_num_points});

    //        var pt_flags = try allocator.alloc(u8, total_num_points);
    //        defer allocator.free(pt_flags);
    //        var flags_read: usize = 0;
    //        while (flags_read < pt_flags.len) {
    //            const flags = try glyph_reader.readByte();
    //            pt_flags[flags_read] = flags;
    //            flags_read += 1;
    //            if ((flags & 0x08) != 0) {
    //                const repeat = try glyph_reader.readByte();
    //                var done: usize = 0;
    //                while (done < repeat) : (done += 1) {
    //                    pt_flags[flags_read] = flags;
    //                    flags_read += 1;
    //                }
    //            }
    //        }
    //        std.debug.print("  flags: [", .{});
    //        for (pt_flags) |flags, idx| {
    //            const str = if (idx == pt_flags.len - 1) "]\n" else ", ";
    //            std.debug.print("0b{b:0>6}{s}", .{ flags, str });
    //        }

    //        const Point = struct {
    //            on_curve: bool,
    //            x: i16,
    //            y: i16,
    //        };

    //        var points = try allocator.alloc(Point, total_num_points);
    //        defer allocator.free(points);
    //        for (pt_flags) |flag, idx| points[idx].on_curve = (flag & 0x01) != 0;
    //        for (pt_flags) |flag, idx| {
    //            const xshort = (flag & 0x02) != 0;
    //            const xsame = (flag & 0x10) != 0;
    //            const last_x = if (idx == 0) 0 else points[idx - 1].x;
    //            if (xshort) {
    //                const byte = try glyph_reader.readByte();
    //                const delta = if (xsame) @intCast(i16, byte) else -@intCast(i16, byte);
    //                points[idx].x = last_x + delta;
    //            } else {
    //                if (xsame) {
    //                    points[idx].x = last_x;
    //                } else {
    //                    const delta = try glyph_reader.readIntBig(i16);
    //                    points[idx].x = last_x + delta;
    //                }
    //            }
    //        }
    //        std.debug.print("\n", .{});
    //        for (pt_flags) |flag, idx| {
    //            const yshort = (flag & 0x04) != 0;
    //            const ysame = (flag & 0x20) != 0;
    //            const last_y = if (idx == 0) 0 else points[idx - 1].y;
    //            if (yshort) {
    //                const byte = try glyph_reader.readByte();
    //                const delta = if (ysame) @intCast(i16, byte) else -@intCast(i16, byte);
    //                points[idx].y = last_y + delta;
    //            } else {
    //                if (ysame) {
    //                    points[idx].y = last_y;
    //                } else {
    //                    const delta = try glyph_reader.readIntBig(i16);
    //                    points[idx].y = last_y + delta;
    //                }
    //            }
    //        }
    //        std.debug.print("  points: [\n", .{});
    //        for (points) |pt| {
    //            std.debug.print("    x={: >5}, y={: >5}, on_curve={}\n", .{ pt.x, pt.y, pt.on_curve });
    //        }
    //        std.debug.print("  ]\n", .{});
    //    }
    //    std.debug.print("there were {} compound glyphs skipped (out of {} total glyphs)\n", .{ compound_glyphs, glyph_locs.items.len });

    //    const glyph = glyph_locs.items[25];
    //    const glyph_data = ttf_data[loc + glyph.offset .. loc + glyph.offset + glyph.size];
    //    g = try decodeGlyph(allocator, glyph_data);
    //    std.debug.print("\n", .{});
    //    std.debug.print("glyph using decoded fn: \n", .{});
    //    for (g.contours) |ct, c_idx| {
    //        std.debug.print("  contour #{}:\n", .{c_idx});
    //        for (ct.segments) |s| {
    //            switch (s) {
    //                .line => |l| std.debug.print("    line: start={}, end={}\n", .{ l.start_point, l.end_point }),
    //                .curve => |c| std.debug.print("    curve: start={}, control={}, end={}\n", .{ c.start_point, c.control_point, c.end_point }),
    //            }
    //        }
    //    }
    //} else return LoadError.NoGlyphTable;

    if (cmap_loc) |loc| {
        std.debug.print("'cmap' table:\n", .{});
        const version = std.mem.readIntSliceBig(u16, ttf_data[loc .. loc + 2]);
        std.debug.print("version = {}\n", .{version});
        const num_subtables = std.mem.readIntSliceBig(u16, ttf_data[loc + 2 .. loc + 4]);
        std.debug.print("num_subtables = {}\n", .{num_subtables});

        var offset = loc + 4;

        var subtable_idx: usize = 0;
        //while (subtable_idx < num_subtables) : (subtable_idx += 1) {
        while (subtable_idx < 1) : (subtable_idx += 1) {
            std.debug.print("subtable #{}:\n", .{subtable_idx});
            const platformID = std.mem.readIntSliceBig(u16, ttf_data[offset .. offset + 2]);
            offset += 2;
            std.debug.print("platformID = {}\n", .{platformID});
            const platformSpecificID = std.mem.readIntSliceBig(u16, ttf_data[offset .. offset + 2]);
            offset += 2;
            std.debug.print("platformSpecificID = {}\n", .{platformSpecificID});
            const table_offset = std.mem.readIntSliceBig(u32, ttf_data[offset .. offset + 4]);
            offset += 4;
            std.debug.print("offset = {} (0x{x})\n", .{ table_offset, table_offset });

            var subtable_offset = loc + table_offset;

            const format = std.mem.readIntSliceBig(u16, ttf_data[subtable_offset .. subtable_offset + 2]);
            subtable_offset += 2;
            std.debug.print("format = {}\n", .{format});
            const length = std.mem.readIntSliceBig(u16, ttf_data[subtable_offset .. subtable_offset + 2]);
            subtable_offset += 2;
            std.debug.print("length = {} (0x{x})\n", .{ length, length });

            var map_table_stream = std.io.fixedBufferStream(ttf_data[subtable_offset .. subtable_offset + length]);
            const map_table_reader = map_table_stream.reader();

            const language = try map_table_reader.readIntBig(u16);
            std.debug.print("language = {}\n", .{language});

            std.debug.assert(format == 4);

            const seg_count = (try map_table_reader.readIntBig(u16)) / 2;
            std.debug.print("seg_count = {}\n", .{seg_count});
            const search_range = try map_table_reader.readIntBig(u16);
            std.debug.print("search_range = {}\n", .{search_range});
            const entry_selector = try map_table_reader.readIntBig(u16);
            std.debug.print("entry_selector = {}\n", .{entry_selector});
            const range_shift = try map_table_reader.readIntBig(u16);
            std.debug.print("range_shift = {}\n", .{range_shift});

            var end_code = try allocator.alloc(u16, seg_count);
            defer allocator.free(end_code);
            for (end_code) |*code| code.* = try map_table_reader.readIntBig(u16);

            try map_table_reader.skipBytes(2, .{});

            var start_code = try allocator.alloc(u16, seg_count);
            defer allocator.free(start_code);
            for (start_code) |*code| code.* = try map_table_reader.readIntBig(u16);

            var id_delta = try allocator.alloc(u16, seg_count);
            defer allocator.free(id_delta);
            for (id_delta) |*code| code.* = try map_table_reader.readIntBig(u16);

            var id_range_offset = try allocator.alloc(u16, seg_count);
            defer allocator.free(id_range_offset);
            for (id_range_offset) |*code| code.* = try map_table_reader.readIntBig(u16);

            std.debug.print("    # | endCode | startCode | idDelta | idRangeOffset\n", .{});
            std.debug.print("  ----+---------+-----------+---------+--------------\n", .{});
            for (end_code) |_, idx| {
                std.debug.print("  {: >3} | {: >7} | {: >9} | {: >7} | {: >7}\n", .{
                    idx,
                    end_code[idx],
                    start_code[idx],
                    id_delta[idx],
                    id_range_offset[idx],
                });
            }

            const space_left_in_table = (try map_table_stream.getEndPos()) - (try map_table_stream.getPos());
            var glyph_idx_array = try allocator.alloc(u16, @divExact(space_left_in_table, @sizeOf(u16)));
            defer allocator.free(glyph_idx_array);
            for (glyph_idx_array) |*idx| idx.* = try map_table_reader.readIntBig(u16);

            std.debug.print("  glyph_idx_array = [\n", .{});
            for (glyph_idx_array) |g_idx, idx| {
                if (idx % 25 == 0) std.debug.print("    ", .{});
                std.debug.print("0x{x:0>4}, ", .{g_idx});
                if (idx % 25 == 24) std.debug.print("\n", .{});
            }
            std.debug.print("]\n", .{});

            const capital_a_acute = 0xc1;
            const code = capital_a_acute;
            const idx = 3;
            const offset_in_u16s = @divExact(id_range_offset[idx], 2) + (code - start_code[idx]);
            std.debug.print("  offset_in_u16s = {}\n", .{offset_in_u16s});
            const glyph_offset = offset_in_u16s - (seg_count - idx);
            std.debug.print("  glyph_offset = {}\n", .{glyph_offset});
            const idx_lookup = glyph_idx_array[glyph_offset];
            std.debug.print("  idx_lookup = {}\n", .{idx_lookup});
            std.debug.print("  actual glyph idx = {}\n", .{idx_lookup + id_delta[idx]});
        }
    } else return LoadError.NoCmapTable;

    return g;
}
