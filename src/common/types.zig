const std = @import("std");
const uuid = @import("uuid");
const oom = @import("utils.zig").oom;
const ObjectId = @import("ids.zig").ObjectId;
const Text = @import("value.zig").Text;

/// A possible type of a value in the database
pub const DBType = enum(u32) {
    oid,
    uint1,
    uint2,
    uint4,
    uint8,
    serial,
    int1,
    int2,
    int4,
    int8,
    const_int,
    boolean,
    long_text,
    text,
    uuid,
    any,

    /// Can this type be silently converted to other type?
    pub fn convertsTo(self: DBType, other: DBType) bool {
        if (self == .any) return true;
        if (std.meta.eql(self, other)) return true;
        if (self == .const_int and other.isNumber()) return true;
        if (self == .oid and other == .uint4) return true;
        if (self == .text and other == .long_text) return true;
        if (self == .long_text and other == .text) return true;
        return false;
    }

    /// Width of this type. Null if the exact width is unknown.
    pub fn width(self: DBType) ?usize {
        return switch (self) {
            .oid => 4,
            .uint1, .int1 => 1,
            .uint2, .int2 => 2,
            .uint4, .int4 => 4,
            .uint8, .int8, .serial => 8,
            .boolean => 1,
            .uuid => 16,
            .text, .long_text => null,
            .any, .const_int => unreachable,
        };
    }

    pub fn isSigned(self: DBType) bool {
        return switch (self) {
            .int1, .int2, .int4, .int8, .const_int => true,
            else => false,
        };
    }

    pub fn isNumber(self: DBType) bool {
        return switch (self) {
            .int1, .int2, .int4, .int8, .uint1, .uint2, .uint4, .uint8, .const_int => true,
            else => false,
        };
    }

    /// Determine the maximum integer size between two types.
    /// Unsigned types are considered bigger than signed.
    pub fn maxIntType(self: DBType, other: DBType) DBType {
        if (std.meta.eql(self, other))
            return self
        else if (self == .const_int)
            return other
        else if (other == .const_int)
            return self
        else if (self.width().? > other.width().?)
            return self
        else if (self.width().? < other.width().?)
            return other
        else if (self.isSigned() and !other.isSigned())
            return self
        else if (!self.isSigned() and other.isSigned())
            return other
        else
            unreachable;
    }

    /// Approximate width of this type.
    /// It must be the exact with for types with known width,
    /// but can be approximate for variable-width types.
    pub fn approximateWidth(self: DBType) usize {
        return switch (self) {
            .oid => 4,
            .uint1, .int1 => 1,
            .uint2, .int2 => 2,
            .uint4, .int4 => 4,
            .uint8, .int8, .serial => 8,
            .boolean => 1,
            .text, .long_text => 8,
            .uuid => 16,
            .any, .const_int => unreachable,
        };
    }

    /// Check if the DBType matches comptime-known type T.
    pub fn checkType(self: DBType, T: type) bool {
        return switch (self) {
            .oid => T == ObjectId,
            .uint1 => T == u8,
            .uint2 => T == u16,
            .uint4 => T == u32,
            .uint8, .serial => T == u64,
            .int1 => T == i8,
            .int2 => T == i16,
            .int4 => T == i32,
            .int8 => T == i64,
            .boolean => T == bool,
            .text, .long_text => T == Text,
            .uuid => T == uuid.Uuid,
            .any, .const_int => unreachable,
        };
    }
};

/// A descriptor of an attribute (or table column).
pub const AttributeDescriptor = struct {
    t: DBType,
    name: []const u8,
};

/// A descriptor of a tuple (or table).
/// Contains types and names of all attributes.
pub const TupleDescriptor = struct {
    attrs: std.ArrayList(AttributeDescriptor) = .empty,
    /// Does the tuple contain extended attributes? (xmin, xmax, pos etc.)
    has_extended: bool = false,

    pub const empty = TupleDescriptor{
        .attrs = .empty,
        .has_extended = false,
    };
    pub const empty_extended = TupleDescriptor{
        .attrs = .empty,
        .has_extended = true,
    };

    pub fn len(self: *const TupleDescriptor) usize {
        return self.attrs.items.len;
    }

    /// Clone the TupleDescriptor.
    pub fn clone(self: *const TupleDescriptor, gpa: std.mem.Allocator) TupleDescriptor {
        const new: TupleDescriptor = .{
            .attrs = self.attrs.clone(gpa) catch oom(),
        };
        for (new.attrs.items) |*att| {
            att.name = gpa.dupe(u8, att.name) catch oom();
        }
        return new;
    }

    /// Are two tuple descriptors the same?
    pub fn eql(lhs: *const TupleDescriptor, rhs: *const TupleDescriptor) bool {
        if (lhs == rhs) return true;
        if (lhs.len() != rhs.len()) return false;
        if (lhs.has_extended != rhs.has_extended) return false;
        for (
            lhs.attrs.items,
            rhs.attrs.items,
        ) |l, r| {
            if (!std.mem.eql(u8, l.name, r.name))
                return false;
            if (l.t != r.t)
                return false;
        }
        return true;
    }

    /// Calculate the approximate width of data in the tuple,
    /// given the TupleDescriptor.
    pub fn approximateWidth(self: *const TupleDescriptor) usize {
        var width: usize = 0;
        for (self.attrs.items) |att| {
            width += att.t.approximateWidth();
        }
        return width;
    }

    /// Find the index of an attribute given its name.
    /// Returns null if there is no such attribute.
    pub fn findAttribute(self: *const TupleDescriptor, name: []const u8) ?usize {
        for (self.attrs.items, 0..) |att, i| {
            if (std.ascii.eqlIgnoreCase(att.name, name))
                return i;
        }
        return null;
    }

    /// Format the tuple descriptor as JSON.
    pub fn jsonStringify(self: *const TupleDescriptor, jws: anytype) !void {
        try jws.beginArray();
        if (self.has_extended)
            try jws.write("<extended>");
        for (self.attrs.items) |att| {
            try jws.beginObject();
            try jws.objectField("name");
            try jws.write(att.name);
            try jws.objectField("type");
            try jws.write(att.t);
            try jws.endObject();
        }
        try jws.endArray();
    }

    /// Format the tuple descriptor as [name: text, i: int4]
    pub fn format(
        self: TupleDescriptor,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.writeAll("[");
        const slice = self.attrs.slice();
        var first = true;
        for (slice.items(.t), slice.items(.name)) |t, name| {
            if (!first)
                try writer.writeAll(", ");
            try writer.print("{s} : {}", .{ name, t });
            first = false;
        }
        try writer.writeAll("]");
    }
};
