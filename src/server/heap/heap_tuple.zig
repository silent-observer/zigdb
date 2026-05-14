const std = @import("std");
const common = @import("common");
const MemTuple = common.MemTuple;
const TupleDescriptor = common.TupleDescriptor;
const oom = common.oom;
const ids = common.ids;

const Header = extern struct {
    count: u16, // Number of attributes
    xmin: ids.RealTransactionId, // ID of transaction that inserted this tuple
    xmax: ids.RealTransactionId, // ID of transaction that deleted this tuple
};

/// Deserialize a MemTuple from HeapTuple.
/// The MemTuple is allocated with a given Allocator.
/// The TupleDescriptor must also be supplied.
pub fn read(
    r: *std.Io.Reader,
    descr: *const TupleDescriptor,
    alloc: std.mem.Allocator,
    pos: MemTuple.Pos,
) !MemTuple {
    std.debug.assert(descr.has_extended);

    const xmin = try r.takeInt(u32, .little);
    const xmax = try r.takeInt(u32, .little);

    const null_bytes_count = std.math.divCeil(
        usize,
        descr.len(),
        8,
    ) catch unreachable;
    const null_bytes = r.readAlloc(alloc, null_bytes_count) catch oom();
    defer alloc.free(null_bytes);

    var b = MemTuple.Builder.init(alloc, descr);
    for (descr.attrs.items, 0..) |att, i| {
        const byte_idx = i / 8;
        const bit_shift: u3 = @intCast(i % 8);
        const is_null = ((null_bytes[byte_idx] >> bit_shift) & 1) != 0;

        if (is_null)
            b.pushValue(.null)
        else
            b.pushValue(try common.Value.read(r, att.t, alloc));
    }
    b.addExtended(.{
        .xmin = .{ .v = xmin },
        .xmax = .{ .v = xmax },
        .pos = pos,
    });
    return b.finalize();
}

/// Serialize a MemTuple as a HeapTuple.
/// pos extended field is ignored.
pub fn write(
    w: *std.Io.Writer,
    tuple: MemTuple,
) !void {
    const descr = tuple.ptr.h.descr;
    std.debug.assert(descr.has_extended);
    const ext = tuple.extended();
    try w.writeInt(u32, ext.xmin.v, .little);
    try w.writeInt(u32, ext.xmax.v, .little);

    var null_byte: u8 = 0;
    for (0..descr.len()) |i| {
        const v = tuple.getValue(i);
        if (v == .null)
            null_byte |= @as(u8, 1) << @intCast(i % 8);

        if (i % 8 == 7) { // Last null bit in byte
            try w.writeByte(null_byte);
            null_byte = 0;
        }
    }
    if (descr.len() % 8 != 0) // Have to push the last byte
        try w.writeByte(null_byte);

    for (descr.attrs.items, 0..) |att, i| {
        const v = tuple.getValue(i);
        try v.write(att.t, w);
    }
}

/// Deserialize only the extended part of a MemTuple from HeapTuple.
/// pos field is undefined.
pub fn readExtended(r: *std.Io.Reader) !MemTuple.ExtendedFields {
    const xmin = try r.takeInt(u32, .little);
    const xmax = try r.takeInt(u32, .little);
    return .{
        .xmin = .{ .v = xmin },
        .xmax = .{ .v = xmax },
        .pos = undefined,
    };
}

/// Serialize only the extended part of a MemTuple as a HeapTuple.
/// pos field is ignored.
pub fn writeExtended(
    w: *std.Io.Writer,
    ext: MemTuple.ExtendedFields,
) !void {
    try w.writeInt(u32, ext.xmin.v, .little);
    try w.writeInt(u32, ext.xmax.v, .little);
}
