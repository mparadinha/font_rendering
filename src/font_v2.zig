const std = @import("std");
const Allocator = std.mem.Allocator;

const Font = @This();

curve_points: []CurvePoint,
glyphs: []Glyph,
//mapping_tables: []MappingTable,

pub const CurvePoint = struct { x: i16, y: i16 };

pub const Glyph = struct {
    /// position in `curve_points` where this glyph's data starts
    points_offset: usize,
    n_points: u16,
    contour_n_curves: []u16,
    xmin: i16,
    ymin: i16,
    xmax: i16,
    ymax: i16,

    pub fn free(self: Glyph, allocator: Allocator) void {
        allocator.free(self.contour_n_curves);
    }
};

pub const MappingTable = struct {};

pub const LoadError = error{
    NotOpenType,
    NoCmapTable,
    NoGlyfTable,
    NoLocaTable,
    NoHeadTable,
    NoMaxpTable,
};

// trying to do this always turns out to be a waste of time. the error sets for stdlib
// functions aren't very tidy
//pub const FileReadError = getFnErrorSet(std.fs.Dir.readFileAlloc);
//pub const ReaderError = error{}; // std.io.FixedBufferStream's ReadError || SeekError
//pub const InitError = FileReadError || ReaderError || LoadError || Allocator.Error;

/// Call `deinit` to clean up resources
pub fn init(allocator: Allocator, filepath: []const u8) !Font {
    const ttf_data = try std.fs.cwd().readFileAlloc(allocator, filepath, std.math.maxInt(usize));
    defer allocator.free(ttf_data);
    const ttf_reader = std.io.fixedBufferStream(ttf_data).reader();

    // https://docs.microsoft.com/en-us/typography/opentype/spec/otff#table-directory

    const open_type_sig = [4]u8{ 0, 1, 0, 0 };
    const sig = try ttf_reader.readBytesNoEof(4);
    if (!std.mem.eql(u8, &sig, &open_type_sig)) return LoadError.NotOpenType;

    // skip some information that used to be usefull for doing binary searchs of the table index
    try ttf_reader.skipBytes(@sizeOf(u16) * 3, .{});

    var maybe_head_data: ?[]const u8 = null;
    var maybe_maxp_data: ?[]const u8 = null;
    var maybe_loca_data: ?[]const u8 = null;
    var maybe_glyf_data: ?[]const u8 = null;
    var maybe_cmap_data: ?[]const u8 = null;

    const n_tables = try ttf_reader.readIntBig(u16);
    var table_idx: usize = 0;
    while (table_idx < n_tables) : (table_idx += 1) {
        const tag = try ttf_reader.readBytesNoEof(4);
        _ = try ttf_reader.readIntBig(u32); // checksum
        const offset = try ttf_reader.readIntBig(u32);
        const length = try ttf_reader.readIntBig(u32);
        if (std.mem.eql(u8, &tag, "head")) maybe_head_data = ttf_data[offset .. offset + length];
        if (std.mem.eql(u8, &tag, "maxp")) maybe_maxp_data = ttf_data[offset .. offset + length];
        if (std.mem.eql(u8, &tag, "loca")) maybe_loca_data = ttf_data[offset .. offset + length];
        if (std.mem.eql(u8, &tag, "glyf")) maybe_glyf_data = ttf_data[offset .. offset + length];
        if (std.mem.eql(u8, &tag, "cmap")) maybe_cmap_data = ttf_data[offset .. offset + length];
    }

    var head_data = maybe_head_data orelse return LoadError.NoHeadTable;
    var maxp_data = maybe_maxp_data orelse return LoadError.NoMaxpTable;
    var loca_data = maybe_loca_data orelse return LoadError.NoLocaTable;
    var glyf_data = maybe_glyf_data orelse return LoadError.NoGlyfTable;
    //var cmap_data = maybe_cmap_data orelse return LoadError.NoCmapTable;

    // https://docs.microsoft.com/en-us/typography/opentype/spec/head
    const index_to_loc_format = readIntBigAtOffset(u16, head_data, 50);

    // https://docs.microsoft.com/en-us/typography/opentype/spec/maxp
    const maxp_reader = std.io.fixedBufferStream(maxp_data).reader();
    _ = try maxp_reader.readIntBig(u32); // table version
    const n_glyphs = try maxp_reader.readIntBig(u16);
    //const max_points = try maxp_reader.readIntBig(u16);
    //const max_contours = try maxp_reader.readIntBig(u16);
    //const max_comp_points = try maxp_reader.readIntBig(u16);
    //const max_comp_contours = try maxp_reader.readIntBig(u16);

    var curve_points = std.ArrayList(CurvePoint).init(allocator);
    var glyphs = try std.ArrayList(Glyph).initCapacity(allocator, n_glyphs);

    // read all the glyph data into `curve_points` and `glyphs`
    var glyph_idx: usize = 0;
    while (glyph_idx < n_glyphs) : (glyph_idx += 1) {
        std.debug.print("glyph_idx={}\n", .{glyph_idx});
        // https://docs.microsoft.com/en-us/typography/opentype/spec/loca
        const glyph_data = switch (index_to_loc_format) {
            0 => blk: {
                const start = readIntBigAtOffset(u16, loca_data, glyph_idx * @sizeOf(u16));
                const end = readIntBigAtOffset(u16, loca_data, (glyph_idx + 1) * @sizeOf(u16));
                break :blk glyf_data[@intCast(usize, start) * 2 .. @intCast(usize, end) * 2];
            },
            1 => blk: {
                const start = 2 * readIntBigAtOffset(u32, loca_data, glyph_idx * @sizeOf(u32));
                const end = 2 * readIntBigAtOffset(u32, loca_data, (glyph_idx + 1) * @sizeOf(u32));
                break :blk glyf_data[@intCast(usize, start) * 2 .. @intCast(usize, end) * 2];
            },
            else => unreachable,
        };
        if (glyph_data.len == 0) continue;
        const glyph_reader = std.io.fixedBufferStream(glyph_data).reader();

        var glyph: Glyph = undefined;
        glyph.points_offset = curve_points.items.len;

        // https://docs.microsoft.com/en-us/typography/opentype/spec/glyf#glyph-headers
        const n_contours = try glyph_reader.readIntBig(i16);
        glyph.xmin = try glyph_reader.readIntBig(i16);
        glyph.ymin = try glyph_reader.readIntBig(i16);
        glyph.xmax = try glyph_reader.readIntBig(i16);
        glyph.ymax = try glyph_reader.readIntBig(i16);

        // TODO: compound glyphs
        if (n_contours < 0) {
            //std.debug.print("compound. skipping.\n", .{});
            continue;
        }

        // https://docs.microsoft.com/en-us/typography/opentype/spec/glyf#simple-glyph-description
        var contour_end_pts = try allocator.alloc(u16, @intCast(usize, n_contours));
        defer allocator.free(contour_end_pts);
        for (contour_end_pts) |*v| v.* = try glyph_reader.readIntBig(u16);
        const instruction_len = try glyph_reader.readIntBig(u16);
        try glyph_reader.skipBytes(instruction_len, .{});
        const n_points = contour_end_pts[@intCast(usize, n_contours) - 1] + 1;
        const decoded_point_data = try decodeGlyphPointData(allocator, glyph_reader, n_points);
        const flags = decoded_point_data.flags;
        defer allocator.free(flags);
        const x_coords = decoded_point_data.x_coords;
        defer allocator.free(x_coords);
        const y_coords = decoded_point_data.y_coords;
        defer allocator.free(y_coords);

        glyph.contour_n_curves = try allocator.alloc(u16, @intCast(usize, n_contours));
        var start_of_contour_curves_pt_idx: usize = undefined;

        // here we normalize the contour segments so that there are ony simple
        // quadratic bezier curves. (line segments get converted to curves too)
        // to save space, the font data for the control points uses some tricks:
        // (which we have to undo)
        // - the segment that closes the contour is sometimes implicit
        // - when two consecutive curves share their last/first control point sometimes
        //   that point is not present in the data.
        //   (i.e. instead of storing this: https://developer.apple.com/fonts/TrueType-Reference-Manual/RM01/fig02.jpg
        //    we get this instead: https://developer.apple.com/fonts/TrueType-Reference-Manual/RM01/fig03.jpg
        //    and to get the omitted control point we just do an average.
        for (contour_end_pts) |end_pt_idx, contour_idx| {
            std.debug.print("end_pt_idx={}\n", .{end_pt_idx});
            start_of_contour_curves_pt_idx = curve_points.items.len;
            var last_point_already_done = false;
            const start_pt_idx = if (contour_idx == 0) 0 else contour_end_pts[contour_idx - 1] + 1;
            for (flags[start_pt_idx .. end_pt_idx + 1]) |flag, i| {
                const pt_idx = i + start_pt_idx;
                const on_curve = (flag & 0x01) != 0;
                const pt = CurvePoint{ .x = x_coords[pt_idx], .y = y_coords[pt_idx] };

                const next_pt_idx = if (pt_idx == end_pt_idx) start_pt_idx else pt_idx + 1;
                const next_on_curve = (flags[next_pt_idx] & 0x01) != 0;
                const next_pt = CurvePoint{ .x = x_coords[next_pt_idx], .y = y_coords[next_pt_idx] };

                // sometimes a contour will start with an off-curve point
                if (i == 0 and !on_curve) {
                    const last_on_curve = (flags[end_pt_idx] & 0x01) != 0;
                    const last_pt = CurvePoint{ .x = x_coords[end_pt_idx], .y = y_coords[end_pt_idx] };
                    if (last_on_curve) {
                        try curve_points.append(last_pt);
                        last_point_already_done = true;
                    } else {
                        try curve_points.append(CurvePoint{
                            .x = @divTrunc(last_pt.x + pt.x, 2),
                            .y = @divTrunc(last_pt.y + pt.y, 2),
                        });
                    }
                }
                if (pt_idx == end_pt_idx and last_point_already_done) continue;

                std.debug.print("adding pt={d: >4}\n", .{pt});
                try curve_points.append(pt);

                // normalize line into a curve by adding an extra control point in the middle
                // the omitted curve control point case mentioned above
                if ((on_curve and next_on_curve) or (!on_curve and !next_on_curve)) {
                    try curve_points.append(CurvePoint{
                        .x = @divTrunc(next_pt.x + pt.x, 2),
                        .y = @divTrunc(next_pt.y + pt.y, 2),
                    });
                    std.debug.print("adding avg pt\n", .{});
                }
            }

            // TODO: add the closing contour segment

            glyph.contour_n_curves[contour_idx] = @divExact(@intCast(u16, curve_points.items.len - start_of_contour_curves_pt_idx), 2);
        }

        glyph.n_points = @intCast(u16, curve_points.items.len - glyph.points_offset);

        try glyphs.append(glyph);
    }

    return Font{
        .curve_points = curve_points.toOwnedSlice(),
        .glyphs = glyphs.toOwnedSlice(),
        //.mapping_tables = undefined,
    };
}

pub fn deinit(self: Font, allocator: Allocator) void {
    allocator.free(self.curve_points);
    for (self.glyphs) |*glyph| glyph.free(allocator);
    allocator.free(self.glyphs);
    //allocator.free(self.mapping_tables);
}

const PointData = struct {
    flags: []u8,
    x_coords: []i16,
    y_coords: []i16,
};
fn decodeGlyphPointData(allocator: Allocator, reader: anytype, n_points: u16) !PointData {
    var flags = try allocator.alloc(u8, n_points);
    var x_coords = try allocator.alloc(i16, n_points);
    var y_coords = try allocator.alloc(i16, n_points);

    // read flags
    var flags_done: usize = 0;
    while (flags_done < n_points) {
        const flag = try reader.readByte();
        flags[flags_done] = flag;
        flags_done += 1;
        if ((flag & 0x08) != 0) {
            const repeat = try reader.readByte();
            var done: usize = 0;
            while (done < repeat) : (done += 1) {
                flags[flags_done] = flag;
                flags_done += 1;
            }
        }
    }
    // read x coords
    for (x_coords) |*x, i| {
        const flag = flags[i];
        const short_flag = (flag & 0x02) != 0;
        const same_flag = (flag & 0x10) != 0;
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
        const flag = flags[i];
        const short_flag = (flag & 0x04) != 0;
        const same_flag = (flag & 0x20) != 0;
        const last_y = if (i == 0) 0 else y_coords[i - 1];
        const delta = if (short_flag) blk: {
            const value = @bitCast(i16, @intCast(u16, try reader.readByte()));
            break :blk if (same_flag) value else -value;
        } else blk: {
            if (same_flag) break :blk 0;
            break :blk try reader.readIntBig(i16);
        };
        y.* = last_y + delta;
    }

    return PointData{
        .flags = flags,
        .x_coords = x_coords,
        .y_coords = y_coords,
    };
}

fn readIntBigAtOffset(comptime Type: type, data: []const u8, offset: usize) Type {
    return std.mem.readIntSliceBig(Type, data[offset .. offset + @sizeOf(Type)]);
}

fn getFnErrorSet(function: anytype) type {
    const fn_type_info = @typeInfo(@TypeOf(function)).Fn;
    const ret_type_info = @typeInfo(fn_type_info.return_type.?);
    return ret_type_info.ErrorUnion.error_set;
}
