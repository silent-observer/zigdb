const std = @import("std");
const uuid = @import("uuid");
const ids = @import("ids.zig");
const t = @import("types.zig");
const oom = @import("utils.zig").oom;

/// Text is a TOASTable sequence of bytes. Short strings are stored raw, while
/// long strings should be TOASTed.
/// In the in-tuple representation, raw strings start with 0x00 byte, while
/// TOASTed strings start with 0x01. This has a nice side effect that Text
/// length is never 0, distinguishing it from NULL. An empty string is represented
/// with a single 0x00 byte.
pub const Text = union(enum) {
    raw: []const u8,
    toast: Toast,

    /// TOAST is a way to store long strings in a separate TOAST table, split into chunks
    /// This means the actual Text value in the tuple is just a reference to a full value
    /// that is stored in the TOAST table.
    pub const Toast = extern struct {
        toast_table_id: ids.TableId, // Which TOAST table is it stored in
        size: u32, // Length of the string
        toast_id: u64, // Id of the toasted value
    };

    pub const ParsingError = error{
        InvalidTextFormat,
    };

    /// Create a raw Text object
    pub fn makeRaw(str: []const u8) Text {
        return .{ .raw = str };
    }

    /// Obtain actual string from a (raw) Text.
    pub fn text(self: Text) []const u8 {
        switch (self) {
            .raw => |r| return r,
            .toast => unreachable,
        }
    }

    /// Get length of the actual string in a (raw) Text.
    pub fn len(self: Text) usize {
        switch (self) {
            .raw => |r| return r.len,
            .toast => unreachable,
        }
    }

    pub fn read(
        r: *std.Io.Reader,
    ) Value.ReadError!Text {
        const size = try r.takeLeb128(i32);
        if (size >= 0) {
            return makeRaw(try r.take(@intCast(size)));
        } else if (size == -1) {
            const toast_table_id = try r.takeInt(ids.TableId, .little);
            const real_size = try r.takeInt(u32, .little);
            const toast_id = try r.takeInt(u64, .little);
            return .{ .toast = .{
                .toast_table_id = toast_table_id,
                .size = real_size,
                .toast_id = toast_id,
            } };
        } else return ParsingError.InvalidTextFormat;
    }

    pub fn write(
        self: *const Text,
        w: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self.*) {
            .raw => |r| {
                try w.writeSleb128(@as(i32, @intCast(r.len)));
                try w.writeAll(r);
            },
            .toast => |toast| {
                try w.writeSleb128(-1);
                try w.writeInt(ids.TableId, toast.toast_table_id, .little);
                try w.writeInt(u32, toast.size, .little);
                try w.writeInt(u64, toast.toast_id, .little);
            },
        }
    }

    pub fn clone(self: Text, alloc: std.mem.Allocator) Text {
        switch (self) {
            .raw => |r| return makeRaw(alloc.dupe(u8, r) catch oom()),
            .toast => return self,
        }
    }

    pub fn deinit(self: Text, alloc: std.mem.Allocator) void {
        switch (self) {
            .raw => |r| alloc.free(r),
            .toast => {},
        }
    }

    pub fn order(lhs: Text, rhs: Text) std.math.Order {
        if (lhs != .raw or rhs != .raw)
            @panic("Toast text comparisons are not supported yet");

        return std.mem.order(u8, lhs.raw, rhs.raw);
    }

    pub fn eql(lhs: Text, rhs: Text) bool {
        if (lhs != .raw or rhs != .raw)
            @panic("Toast text comparisons are not supported yet");

        return std.mem.eql(u8, lhs.raw, rhs.raw);
    }
};

/// Value of runtime-known type.
/// The type is not actually specified, only the value is.
pub const Value = union(enum) {
    int: i64,
    text: Text,
    boolean: bool,
    uuid: uuid.Uuid,
    array: []Value,
    null: void,

    pub const ReadError = error{
        Overflow,
        InvalidTextFormat,
    } || std.Io.Reader.Error;
    pub const TypeError = error{InvalidType};

    /// Obtain comptime-known type from a Value.
    pub fn to(v: Value, comptime T: type) TypeError!T {
        if (T == Value) return v;

        if (@typeInfo(T) == .optional) {
            if (v == .null)
                return null
            else
                return try v.to(@typeInfo(T).optional.child);
        }

        if (@typeInfo(T) == .pointer) {
            // We do not support destructuring []T without allocators
            if (T != []Value or v != .array)
                return TypeError.InvalidType
            else
                return v.array;
        }

        switch (T) {
            i8, i16, i32, i64, u8, u16, u32, u64 => if (v == .int)
                return @intCast(v.int)
            else
                return TypeError.InvalidType,
            Text => if (v == .text)
                return v.text
            else
                return TypeError.InvalidType,
            bool => if (v == .boolean)
                return v.boolean
            else
                return TypeError.InvalidType,
            uuid.Uuid => if (v == .uuid)
                return v.uuid
            else
                return TypeError.InvalidType,
            t.DBType => if (v == .text) {
                var r = std.Io.Reader.fixed(v.text.text());
                return t.DBType.read(&r) catch return TypeError.InvalidType;
            } else return TypeError.InvalidType,
            else => return TypeError.InvalidType,
        }
    }

    /// Obtain comptime-known type from a Value.
    pub fn from(comptime T: type, v: T, alloc: std.mem.Allocator) Value {
        if (T == Value) return v;

        if (@typeInfo(T) == .optional) {
            if (v == null)
                return .null
            else
                return from(@typeInfo(T).optional.child, v.?, alloc);
        }

        if (@typeInfo(T) == .pointer) {
            const E = @typeInfo(T).pointer.child;
            const arr = alloc.alloc(Value, v.len) catch oom();
            for (v, arr) |child_t, *child_val| {
                child_val.* = from(E, child_t, alloc);
            }
            return .{ .array = arr };
        }

        return switch (T) {
            i8, i16, i32, i64, u8, u16, u32, u64 => .{ .int = @intCast(v) },
            Text => .{ .text = v.clone(alloc) },
            bool => .{ .boolean = v },
            uuid.Uuid => .{ .uuid = v },
            t.DBType => block: {
                var writer = std.Io.Writer.Allocating.init(alloc);
                v.write(&writer.writer) catch oom();
                break :block .{ .text = .makeRaw(writer.written()) };
            },
            else => comptime unreachable,
        };
    }

    /// Check if type of Value matches given DBType.
    pub fn checkType(v: Value, dbtype: t.DBType) bool {
        if (v == .null) return true;
        switch (dbtype) {
            .oid,
            .int1,
            .int2,
            .int4,
            .int8,
            .uint1,
            .uint2,
            .uint4,
            .uint8,
            .serial,
            => return v == .int,
            .text, .long_text => return v == .text,
            .boolean => return v == .boolean,
            .uuid => return v == .uuid,
            .nulltype => return false, // Should have returned true earlier
        }
    }

    /// Format the Value as string.
    pub fn format(
        self: Value,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .int => |x| try writer.print("{}", .{x}),
            .text => |s| try writer.print("\"{s}\"", .{s.text()}),
            .boolean => |b| try writer.print("{}", .{b}),
            .uuid => |u| try writer.print("{s}", .{&uuid.urn.serialize(u)}),
            .array => |a| {
                try writer.writeByte('[');
                for (a, 0..) |v, i| {
                    if (i > 0)
                        try writer.writeAll(", ");
                    try v.format(writer);
                }
                try writer.writeByte(']');
            },
            .null => try writer.writeAll("NULL"),
        }
    }

    /// Format the Value as string.
    pub fn formatForClient(
        self: Value,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .boolean => |b| try writer.writeByte(if (b) 't' else 'f'),
            .int => |x| try writer.print("{}", .{x}),
            .text => |s| try writer.writeAll(s.text()),
            .uuid => |u| try writer.writeAll(&uuid.urn.serialize(u)),
            .null => {},
            .array => |a| {
                try writer.writeByte('[');
                for (a, 0..) |v, i| {
                    if (i > 0)
                        try writer.writeAll(", ");
                    try v.formatForClient(writer);
                }
                try writer.writeByte(']');
            },
        }
    }

    /// Calculate the width it would require to print this as text
    pub fn calcTextWidth(self: Value) usize {
        switch (self) {
            .int => |x| {
                return if (x == 0)
                    1
                else if (x > 0)
                    1 + std.math.log10_int(@as(u64, @intCast(x)))
                else
                    2 + std.math.log10_int(@as(u64, @intCast(-x)));
            },
            .text => |s| return s.len(),
            .array => |a| {
                var count = a.len * 2; // 2 for [] + 2 for each comma
                for (a) |v| {
                    count += v.calcTextWidth();
                }
                return count;
            },
            .boolean => return 1,
            .uuid => return 36,
            .null => return 0,
        }
    }

    pub fn read(
        r: *std.Io.Reader,
        dbtype: t.DBType,
        alloc: std.mem.Allocator,
    ) ReadError!Value {
        switch (dbtype) {
            .base => |base| switch (base) {
                .uint1 => return .{ .int = @intCast(try r.takeInt(u8, .little)) },
                .uint2 => return .{ .int = @intCast(try r.takeInt(u16, .little)) },
                .uint4, .serial => return .{ .int = @intCast(try r.takeInt(u32, .little)) },
                .uint8, .oid => return .{ .int = @intCast(try r.takeInt(u64, .little)) },
                .int1 => return .{ .int = @intCast(try r.takeInt(i8, .little)) },
                .int2 => return .{ .int = @intCast(try r.takeInt(i16, .little)) },
                .int4 => return .{ .int = @intCast(try r.takeInt(i32, .little)) },
                .int8 => return .{ .int = @intCast(try r.takeInt(i64, .little)) },
                .uuid => return .{ .int = @intCast(try r.takeInt(uuid.Uuid, .little)) },
                .boolean => return .{ .boolean = try r.takeByte() != 0 },
                .nulltype => return .null,
                .text, .long_text, .dbtype => return .{ .text = try Text.read(r) },
            },
            .arr => |arr| {
                const size = try r.takeLeb128(usize);
                const data = alloc.alloc(Value, size) catch oom();
                for (data) |*v|
                    v.* = try read(r, arr.child(), alloc);
                return .{ .array = data };
            },
        }
    }

    pub fn write(
        self: Value,
        dbtype: t.DBType,
        w: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        if (self == .null) return;
        switch (dbtype) {
            .base => |base| switch (base) {
                .uint1 => try w.writeInt(u8, @intCast(self.int), .little),
                .uint2 => try w.writeInt(u16, @intCast(self.int), .little),
                .uint4, .serial => try w.writeInt(u32, @intCast(self.int), .little),
                .uint8, .oid => try w.writeInt(u64, @intCast(self.int), .little),
                .int1 => try w.writeInt(i8, @intCast(self.int), .little),
                .int2 => try w.writeInt(i16, @intCast(self.int), .little),
                .int4 => try w.writeInt(i32, @intCast(self.int), .little),
                .int8 => try w.writeInt(i64, @intCast(self.int), .little),
                .uuid => try w.writeInt(uuid.Uuid, self.uuid, .little),
                .boolean => try w.writeByte(@intFromBool(self.boolean)),
                .nulltype => unreachable,
                .text, .long_text, .dbtype => try self.text.write(w),
            },
            .arr => |arr| {
                try w.writeLeb128(self.array.len);
                for (self.array) |v|
                    try v.write(arr.child(), w);
            },
        }
    }

    pub fn clone(self: Value, alloc: std.mem.Allocator) Value {
        switch (self) {
            .int, .boolean, .null, .uuid => return self,
            .text => |text| return .{ .text = text.clone(alloc) },
            .array => |arr| {
                const new = alloc.dupe(Value, arr) catch oom();
                for (new) |*v| v.* = v.clone(alloc);
                return .{ .array = new };
            },
        }
    }

    pub fn deinit(self: Value, alloc: std.mem.Allocator) void {
        switch (self) {
            .int, .boolean, .null, .uuid => {},
            .text => |text| text.deinit(alloc),
            .array => |arr| {
                for (arr) |v| v.deinit(alloc);
                alloc.free(arr);
            },
        }
    }

    pub fn order(lhs: Value, rhs: Value, dbtype: t.DBType) std.math.Order {
        if (lhs == .null and rhs == .null)
            return .eq;
        if (lhs == .null) return .gt;
        if (rhs == .null) return .lt;

        switch (dbtype) {
            .base => |base| switch (base) {
                .uint1,
                .uint2,
                .uint4,
                .uint8,
                => return std.math.order(
                    @as(u64, @intCast(lhs.int)),
                    @as(u64, @intCast(rhs.int)),
                ),
                .oid,
                .serial,
                .int1,
                .int2,
                .int4,
                .int8,
                => return std.math.order(lhs.int, rhs.int),
                .uuid => return std.math.order(lhs.uuid, rhs.uuid),
                .boolean => return std.math.order(
                    @intFromBool(lhs.boolean),
                    @intFromBool(rhs.boolean),
                ),
                .text, .long_text, .dbtype => return lhs.text.order(rhs.text),
                .nulltype => unreachable,
            },
            .arr => |arr| {
                const prefix_len = @min(lhs.array.len, rhs.array.len);
                for (lhs.array[0..prefix_len], rhs.array[0..prefix_len]) |l, r| {
                    const o = order(l, r, arr.child());
                    if (o != .eq) return o;
                }
                return std.math.order(lhs.array.len, rhs.array.len);
            },
        }
    }

    pub fn eql(lhs: Value, rhs: Value, dbtype: t.DBType) bool {
        if (lhs == .null and rhs == .null)
            return true;
        if (lhs == .null or rhs == .null)
            return false;

        switch (dbtype) {
            .base => |base| switch (base) {
                .uint1,
                .uint2,
                .uint4,
                .uint8,
                .oid,
                .serial,
                .int1,
                .int2,
                .int4,
                .int8,
                => return lhs.int == rhs.int,
                .uuid => return lhs.uuid == rhs.uuid,
                .boolean => return lhs.boolean == rhs.boolean,
                .text, .long_text, .dbtype => return lhs.text.eql(rhs.text),
                .nulltype => unreachable,
            },
            .arr => |arr| {
                if (lhs.array.len != rhs.array.len) return false;
                for (lhs.array, rhs.array) |l, r| {
                    if (!eql(l, r, arr.child()))
                        return false;
                }
                return true;
            },
        }
    }
};

/// Value together with its type.
/// Fully specifies the typed value, but is usually unnecessary,
/// since the type can usually be inferred from context.
pub const TypedValue = struct {
    v: Value,
    t: t.DBType,
};
