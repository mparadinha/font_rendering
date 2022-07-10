const std = @import("std");
const Allocator = std.mem.Allocator;

pub const LoadError = error{
    NotOpenType,
    NoCmapTable,
    NoGlyfTable,
    NoLocaTable,
    NoHeadTable,
    NoMaxpTable,
};

pub const Glyf = struct {
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

    pub fn free(self: Glyf, allocator: Allocator) void {
        for (self.contours) |contour| allocator.free(contour.segments);
        allocator.free(self.contours);
    }
};

/// Caller owns returned memory. Call glyf.free(allocator) to clean up.
fn decodeGlyf(allocator: Allocator, data: []u8) !Glyf {
    const reader = std.io.fixedBufferStream(data).reader();

    var glyf: Glyf = undefined;

    const num_contours = try reader.readIntBig(i16);
    if (num_contours < 0) {
        std.debug.print("ignoring compound contours for now\n", .{});
        return glyf;
    }
    glyf.contours = try allocator.alloc(Glyf.Contour, @intCast(usize, num_contours));

    glyf.xmin = try reader.readIntBig(i16);
    glyf.ymin = try reader.readIntBig(i16);
    glyf.xmax = try reader.readIntBig(i16);
    glyf.ymax = try reader.readIntBig(i16);

    // TODO: compound glyfs
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

    // convert points into lists of segments
    for (glyf.contours) |*contour, contour_idx| {
        var segments = std.ArrayList(Glyf.Segment).init(allocator);

        const start_point_idx = if (contour_idx == 0) 0 else end_points[contour_idx - 1] + 1;
        var point_idx: usize = start_point_idx;
        while (point_idx <= end_points[contour_idx]) {
            const on_curve = (point_flags[point_idx] & 0x01) != 0;
            std.debug.assert(on_curve);

            // if the last point is on_curve then it's a line segment that
            // connects back to the first point and closes the contour
            if (point_idx == end_points[contour_idx]) {
                try segments.append(.{ .line = .{
                    .start_point = .{
                        .x = x_coords[point_idx],
                        .y = y_coords[point_idx],
                    },
                    .end_point = .{
                        .x = x_coords[start_point_idx],
                        .y = y_coords[start_point_idx],
                    },
                } });
                point_idx += 1;
                continue;
            }

            const next_is_on_curve = (point_flags[point_idx + 1] & 0x01) != 0;

            // two consecutive points with on_curve set to true means we
            // have a line segment
            if (next_is_on_curve) {
                try segments.append(.{ .line = .{
                    .start_point = .{
                        .x = x_coords[point_idx],
                        .y = y_coords[point_idx],
                    },
                    .end_point = .{
                        .x = x_coords[point_idx + 1],
                        .y = y_coords[point_idx + 1],
                    },
                } });
                point_idx += 1;
                continue;
            }

            // on_curve, followed by not on_curve as the last point of the contour
            // means we have quadratic bezier curve whose final control point
            // is the starting point of the contour. this closes the contour.
            if (point_idx + 2 == end_points[contour_idx]) {
                try segments.append(.{ .curve = .{
                    .start_point = .{
                        .x = x_coords[point_idx],
                        .y = y_coords[point_idx],
                    },
                    .control_point = .{
                        .x = x_coords[point_idx + 1],
                        .y = y_coords[point_idx + 1],
                    },
                    .end_point = .{
                        .x = x_coords[start_point_idx],
                        .y = y_coords[start_point_idx],
                    },
                } });
                point_idx += 2;
                continue;
            }

            const next_next_is_on_curve = (point_flags[point_idx + 2] & 0x01) != 0;
            std.debug.assert(next_next_is_on_curve);

            try segments.append(.{ .curve = .{
                .start_point = .{
                    .x = x_coords[point_idx],
                    .y = y_coords[point_idx],
                },
                .control_point = .{
                    .x = x_coords[point_idx + 1],
                    .y = y_coords[point_idx + 1],
                },
                .end_point = .{
                    .x = x_coords[point_idx + 2],
                    .y = y_coords[point_idx + 2],
                },
            } });
            point_idx += 3;
        }

        contour.segments = segments.toOwnedSlice();
    }

    return glyf;
}

pub fn loadTTF(allocator: Allocator, filepath: []const u8) !Glyf {
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

    const num_glyfs = if (maxp_loc) |loc| std.mem.readIntSliceBig(u16, ttf_data[loc + 4 .. loc + 6]) else return LoadError.NoMaxpTable;
    std.debug.print("num_glyfs = {}\n", .{num_glyfs});

    var index_to_loc_format: usize = undefined;

    if (head_loc) |loc| {
        std.debug.print("'head' table:\n", .{});
        index_to_loc_format = std.mem.readIntSliceBig(u16, ttf_data[loc + 50 .. loc + 52]);
        std.debug.print("indexToLocFormat = {}\n", .{index_to_loc_format});
    } else return LoadError.NoHeadTable;

    var glyf_locs = std.ArrayList(struct { offset: usize, size: usize }).init(allocator);
    defer glyf_locs.deinit();

    if (loca_loc) |loc| {
        std.debug.print("'loca' table:\n", .{});
        i = 0;
        const loca_offsets_size: usize = if (index_to_loc_format == 1) 4 else 2;
        while (i < num_glyfs + 1) : (i += 1) {
            const loc_offset = loc + loca_offsets_size * i;
            const glyf_offset_data = ttf_data[loc_offset .. loc_offset + loca_offsets_size];
            const glyf_offset = switch (loca_offsets_size) {
                2 => @intCast(u32, std.mem.readIntSliceBig(u16, glyf_offset_data)),
                4 => std.mem.readIntSliceBig(u32, glyf_offset_data),
                else => unreachable,
            } * if (index_to_loc_format == 1) @as(usize, 1) else @as(usize, 2);

            if (i > 0 and i < num_glyfs) {
                const last_offset = glyf_locs.items[glyf_locs.items.len - 1].offset;
                glyf_locs.items[glyf_locs.items.len - 1].size = glyf_offset - last_offset;
            }

            try glyf_locs.append(.{ .offset = glyf_offset, .size = 0 });
        }
    } else return LoadError.NoLocaTable;

    //for (glyf_locs.items) |loc, idx| std.debug.print("glyf #{: >4}: offset={: >5}, size={: >4}\n", .{ idx, loc.offset, loc.size });

    if (glyf_loc) |loc| {
        var compound_glyfs: usize = 0;
        for (glyf_locs.items) |glyf, glyf_idx| {
            std.debug.print("glyf #{}: offset={}, size={}\n", .{ glyf_idx, glyf.offset, glyf.size });
            if (glyf.size == 0) continue;

            const glyf_data = ttf_data[loc + glyf.offset .. loc + glyf.offset + glyf.size];
            var glyf_stream = std.io.fixedBufferStream(glyf_data);
            const glyf_reader = glyf_stream.reader();

            const num_contours = try glyf_reader.readIntBig(i16);
            std.debug.print("  # of contours: {}\n", .{num_contours});
            const xmin = try glyf_reader.readIntBig(i16);
            const ymin = try glyf_reader.readIntBig(i16);
            const xmax = try glyf_reader.readIntBig(i16);
            const ymax = try glyf_reader.readIntBig(i16);
            std.debug.print("  xmin: {}, ymin: {} (FUnits)\n", .{ xmin, ymin });
            std.debug.print("  xmax: {}, ymax: {} (FUnits)\n", .{ xmax, ymax });

            // TODO: deal with compound glyfs
            //std.debug.assert(num_contours >= 0);
            if (num_contours < 0) {
                std.debug.print("glyf idx={} is compound. skipping.\n", .{glyf_idx});
                compound_glyfs += 1;
                continue;
            }

            var total_num_points: u16 = 0;

            std.debug.print("  end pts of contours: [", .{});
            var contour: usize = 0;
            while (contour < num_contours) : (contour += 1) {
                const end_pt = try glyf_reader.readIntBig(u16);
                const str = if (contour == num_contours - 1) "]\n" else ", ";
                std.debug.print("{}{s}", .{ end_pt, str });
                // TODO: report this bug to zig compiler repo (might be fixed in stage2):
                // this prints the "]\n" twice:
                //std.debug.print("{}{s}", .{ end_pt, if (contour == num_contours - 1) "]\n" else ", " });
                // but if we put it in a variable it works:
                //const str = if (contour == num_contours - 1) "]\n" else ", ";
                //std.debug.print("{}{s}", .{ end_pt, str });

                if (contour == num_contours - 1) total_num_points = end_pt + 1;
            }

            const instructions_len = try glyf_reader.readIntBig(u16);
            std.debug.print("  instructions: [", .{});
            var insts: usize = 0;
            while (insts < instructions_len) : (insts += 1) {
                const inst = try glyf_reader.readByte();
                const str = if (insts == instructions_len - 1) "]\n" else ", ";
                std.debug.print("0x{x:0>2}{s}", .{ inst, str });
            }

            std.debug.print("  # of points: {}\n", .{total_num_points});

            var pt_flags = try allocator.alloc(u8, total_num_points);
            defer allocator.free(pt_flags);
            var flags_read: usize = 0;
            while (flags_read < pt_flags.len) {
                const flags = try glyf_reader.readByte();
                pt_flags[flags_read] = flags;
                flags_read += 1;
                if ((flags & 0x08) != 0) {
                    const repeat = try glyf_reader.readByte();
                    var done: usize = 0;
                    while (done < repeat) : (done += 1) {
                        pt_flags[flags_read] = flags;
                        flags_read += 1;
                    }
                }
            }
            std.debug.print("  flags: [", .{});
            for (pt_flags) |flags, idx| {
                const str = if (idx == pt_flags.len - 1) "]\n" else ", ";
                std.debug.print("0b{b:0>6}{s}", .{ flags, str });
            }

            const Point = struct {
                on_curve: bool,
                x: i16,
                y: i16,
            };

            var points = try allocator.alloc(Point, total_num_points);
            defer allocator.free(points);
            for (pt_flags) |flag, idx| points[idx].on_curve = (flag & 0x01) != 0;
            for (pt_flags) |flag, idx| {
                const xshort = (flag & 0x02) != 0;
                const xsame = (flag & 0x10) != 0;
                const last_x = if (idx == 0) 0 else points[idx - 1].x;
                if (xshort) {
                    const byte = try glyf_reader.readByte();
                    const delta = if (xsame) @intCast(i16, byte) else -@intCast(i16, byte);
                    points[idx].x = last_x + delta;
                } else {
                    if (xsame) {
                        points[idx].x = last_x;
                    } else {
                        const delta = try glyf_reader.readIntBig(i16);
                        points[idx].x = last_x + delta;
                    }
                }
            }
            std.debug.print("\n", .{});
            for (pt_flags) |flag, idx| {
                const yshort = (flag & 0x04) != 0;
                const ysame = (flag & 0x20) != 0;
                const last_y = if (idx == 0) 0 else points[idx - 1].y;
                if (yshort) {
                    const byte = try glyf_reader.readByte();
                    const delta = if (ysame) @intCast(i16, byte) else -@intCast(i16, byte);
                    points[idx].y = last_y + delta;
                } else {
                    if (ysame) {
                        points[idx].y = last_y;
                    } else {
                        const delta = try glyf_reader.readIntBig(i16);
                        points[idx].y = last_y + delta;
                    }
                }
            }
            std.debug.print("  points: [\n", .{});
            for (points) |pt| {
                std.debug.print("    x={: >5}, y={: >5}, on_curve={}\n", .{ pt.x, pt.y, pt.on_curve });
            }
            std.debug.print("  ]\n", .{});

            if (glyf_idx == 4) {
                const g = try decodeGlyf(allocator, glyf_data);
                std.debug.print("\n", .{});
                std.debug.print("glyf using decoded fn: \n", .{});
                for (g.contours) |ct, c_idx| {
                    std.debug.print("  contour #{}:\n", .{c_idx});
                    for (ct.segments) |s| {
                        switch (s) {
                            .line => |l| std.debug.print("    line: start={}, end={}\n", .{ l.start_point, l.end_point }),
                            .curve => |c| std.debug.print("    curve: start={}, control={}, end={}\n", .{ c.start_point, c.control_point, c.end_point }),
                        }
                    }
                }
                return g;
            }
        }
        std.debug.print("there were {} compound glyfs skipped (out of {} total glyfs)\n", .{ compound_glyfs, glyf_locs.items.len });
    } else return LoadError.NoGlyfTable;

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

            std.debug.print("pos={0d:} (0x{0x:})\n", .{map_table_stream.getPos()});
        }
    } else return LoadError.NoCmapTable;

    @panic("woops");
}
