//! Representation of a table with data that we received from server

const std = @import("std");
const common = @import("common");

const Table = @This();

/// Arena used to allocate all the data.
arena: std.heap.ArenaAllocator,
/// Tuple descriptor. Might be empty if we don't have it yet.
descr: ?common.TupleDescriptor,
/// List of tuples in the table
tuples: std.ArrayList(common.MemTuple),

/// Create a new empty table.
pub fn init(gpa: std.mem.Allocator) Table {
    return .{
        .arena = .init(gpa),
        .descr = null,
        .tuples = .empty,
    };
}

/// Reset the table before filling it.
pub fn reset(self: *Table) void {
    _ = self.arena.reset(.retain_capacity);
    self.descr = null;
    self.tuples = .empty;
}

/// Add a new tuple to the table.
pub fn append(self: *Table, t: common.MemTuple) void {
    self.tuples.append(self.arena.allocator(), t) catch common.oom();
}

/// Format the table.
pub fn format(
    self: Table,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    var buffer: [256]u16 = undefined;

    // Fill column widths with widths of the headers
    var max_widths: std.ArrayList(u16) = .initBuffer(&buffer);
    for (self.descr.?.attrs.items(.name)) |name|
        max_widths.appendBounded(@intCast(name.len)) catch common.oom();

    // Go through all the tuples
    for (self.tuples.items) |t| {
        for (0..self.descr.?.attrs.len) |i| {
            const width = t.getValue(i).calcTextWidth();
            // Calculate the maximum width of each column
            max_widths.items[i] = @intCast(@max(max_widths.items[i], width));
        }
    }

    // Write the header
    for (self.descr.?.attrs.items(.name), max_widths.items, 0..) |name, w, i| {
        if (i > 0)
            try writer.writeByte('|');
        const total_pad = w - name.len;
        const left_pad = total_pad / 2;
        const right_pad = total_pad - left_pad;
        try writer.splatByteAll(' ', left_pad + 1);
        try writer.writeAll(name);
        try writer.splatByteAll(' ', right_pad + 1);
    }
    try writer.writeByte('\n');
    // Write the header line
    for (max_widths.items, 0..) |w, i| {
        if (i > 0)
            try writer.writeByte('+');
        try writer.splatByteAll('-', w + 2);
    }
    try writer.writeByte('\n');
    // Write the rows
    for (self.tuples.items) |t| {
        for (max_widths.items, 0..) |w, i| {
            if (i > 0)
                try writer.writeByte('|');
            const v = t.getValue(i);
            const width = v.calcTextWidth();

            const total_pad = w - width;
            const left_pad = switch (v) {
                .boolean, .text, .null => 0,
                .int => total_pad,
            };
            const right_pad = total_pad - left_pad;
            try writer.splatByteAll(' ', left_pad + 1);

            switch (v) {
                .boolean => |b| try writer.writeByte(if (b) 't' else 'f'),
                .int => |x| try writer.print("{}", .{x}),
                .text => |s| try writer.writeAll(s.text()),
                .null => {},
            }

            try writer.splatByteAll(' ', right_pad + 1);
        }
        try writer.writeByte('\n');
    }
    // Write the count
    try writer.print("({} rows)\n\n", .{self.tuples.items.len});
}

/// Format the table as a JSON object.
pub fn jsonStringify(self: Table, jws: anytype) !void {
    try jws.beginObject();
    {
        try jws.objectField("columns");
        try jws.write(self.descr);
    }
    {
        try jws.objectField("count");
        try jws.write(self.tuples.len);
    }
    {
        try jws.objectField("data");
        try jws.beginArray();
        for (self.tuples) |t|
            try jws.write(t);
        try jws.endArray();
    }
    try jws.endObject();
}
