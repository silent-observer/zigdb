const std = @import("std");
const uuid = @import("uuid");
const oom = @import("utils.zig").oom;
const ObjectId = @import("ids.zig").ObjectId;
const Text = @import("value.zig").Text;

/// A possible type of a value in the database
pub const DBType = union(enum) {
    base: Base,
    arr: Array,

    pub fn b(base: Base) DBType {
        return .{ .base = base };
    }

    pub const Base = enum {
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
        boolean,
        long_text,
        text,
        dbtype,
        uuid,
        nulltype,
    };

    pub const base_type_strs: std.EnumArray(Base, []const u8) = .init(.{
        .oid = "OI",
        .uint1 = "U1",
        .uint2 = "U2",
        .uint4 = "U4",
        .uint8 = "U8",
        .int1 = "I1",
        .int2 = "I2",
        .int4 = "I4",
        .int8 = "I8",
        .serial = "SE",
        .boolean = "BO",
        .text = "TX",
        .long_text = "LT",
        .dbtype = "TY",
        .uuid = "UU",
        .nulltype = "NU",
    });

    pub const base_type_str_map: std.StaticStringMap(Base) = .initComptime(block: {
        const BaseStr = struct { []const u8, Base };
        const count = std.enums.values(Base).len;
        // Make an array of keyword entries, each containing its text and enum value
        var result: [count]BaseStr = undefined;
        // Go through all possible keywords and fill the array
        for (std.enums.values(Base), 0..) |kw, i| {
            result[i] = .{ base_type_strs.get(kw), kw };
        }
        // Build a string map from it
        break :block result;
    });

    pub const Array = struct {
        count: u3 = 1,
        base: Base,

        pub fn child(self: Array) DBType {
            if (self.count == 1)
                return .b(self.base)
            else
                return .{ .arr = .{
                    .count = self.count - 1,
                    .base = self.base,
                } };
        }
    };

    pub fn writeLen(self: DBType) usize {
        switch (self) {
            .arr => |a| return a.count + writeLen(.b(a.base)),
            .base => return 2,
        }
    }

    pub fn write(self: DBType, w: *std.Io.Writer) !void {
        switch (self) {
            .arr => |a| {
                try w.splatByteAll('[', a.count);
                try write(.{ .base = a.base }, w);
            },
            .base => |base| try w.writeAll(base_type_strs.get(base)),
        }
    }

    pub fn read(r: *std.Io.Reader) !DBType {
        if (try r.peekByte() == '[') { // Array
            r.toss(1);
            const child = try read(r);
            switch (child) {
                .arr => |a| return .{ .arr = .{
                    .base = a.base,
                    .count = a.count + 1,
                } },
                .base => |base| return .{ .arr = .{
                    .base = base,
                    .count = 1,
                } },
            }
        }

        const s = try r.take(2);
        if (base_type_str_map.get(s)) |base|
            return .b(base)
        else
            return error.UnknownTypeError;
    }

    /// Can this type be silently converted to other type?
    pub fn convertsTo(self: DBType, other: DBType) bool {
        if (std.meta.eql(self, other)) return true;
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;

        if (self == .arr and other == .arr)
            return self.arr.count == other.arr.count and
                convertsTo(
                    .b(self.arr.base),
                    .b(other.arr.base),
                );

        if (self.base == .nulltype) return true;
        if (self.base == .oid and other.base == .uint4) return true;
        if (self.base == .text and other.base == .long_text) return true;
        if (self.base == .long_text and other.base == .text) return true;
        return false;
    }

    /// Width of this type. Null if the exact width is unknown.
    pub fn width(self: DBType) ?usize {
        return switch (self) {
            .arr => null,
            .base => |base| switch (base) {
                .oid => 4,
                .uint1, .int1 => 1,
                .uint2, .int2 => 2,
                .uint4, .int4 => 4,
                .uint8, .int8, .serial => 8,
                .boolean => 1,
                .uuid => 16,
                .nulltype => 0,
                .text, .long_text, .dbtype => null,
            },
        };
    }

    pub fn isSigned(self: DBType) bool {
        if (self != .base) return false;
        return switch (self.base) {
            .int1, .int2, .int4, .int8 => true,
            else => false,
        };
    }

    pub fn isNumber(self: DBType) bool {
        if (self != .base) return false;
        return switch (self.base) {
            .int1, .int2, .int4, .int8, .uint1, .uint2, .uint4, .uint8 => true,
            else => false,
        };
    }

    /// Determine the maximum integer size between two types.
    /// Unsigned types are considered bigger than signed.
    pub fn maxIntType(self: DBType, other: DBType) DBType {
        if (std.meta.eql(self.base, other.base))
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

    /// Check if the DBType matches comptime-known type T.
    pub fn checkType(self: DBType, T: type) bool {
        return switch (self) {
            .base => |base| switch (base) {
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
                .dbtype => T == DBType,
                .nulltype => unreachable,
            },
            .arr => |a| if (@typeInfo(T) != .pointer)
                false
            else
                checkType(
                    a.child(),
                    @typeInfo(T).pointer.child,
                ),
        };
    }

    /// Format the tuple descriptor as [name: text, i: int4]
    pub fn format(
        self: DBType,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .base => |base| switch (base) {
                .oid => try writer.writeAll("OID"),
                .uint1 => try writer.writeAll("UINT1"),
                .uint2 => try writer.writeAll("UINT2"),
                .uint4 => try writer.writeAll("UINT4"),
                .uint8 => try writer.writeAll("UINT8"),
                .serial => try writer.writeAll("SERIAL"),
                .int1 => try writer.writeAll("INT1"),
                .int2 => try writer.writeAll("INT2"),
                .int4 => try writer.writeAll("INT4"),
                .int8 => try writer.writeAll("INT8"),
                .boolean => try writer.writeAll("BOOLEAN"),
                .long_text => try writer.writeAll("LONG TEXT"),
                .text => try writer.writeAll("TEXT"),
                .uuid => try writer.writeAll("UUID"),
                .dbtype => try writer.writeAll("TYPE"),
                .nulltype => try writer.writeAll("NULL"),
            },
            .arr => |a| {
                try format(.{ .base = a.base }, writer);
                try writer.splatBytesAll("[]", a.count);
            },
        }
    }
};

/// A descriptor of an attribute (or table column).
pub const AttributeDescriptor = struct {
    t: DBType,
    name: []const u8,
    table_name: []const u8 = "",
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
            if (std.meta.eql(l.t, r.t))
                return false;
        }
        return true;
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
