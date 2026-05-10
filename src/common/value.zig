const std = @import("std");
const t = @import("types.zig");
const oom = @import("utils.zig").oom;

/// Text is a special type, because it always starts with a 0 byte to distinguish from NULL
pub const Text = union(enum) {
    raw: []const u8,

    pub fn fromBytes(bytes: []const u8) Text {
        return switch (bytes[0]) {
            0x00 => .{ .raw = bytes[1..] },
            else => unreachable,
        };
    }

    pub fn makeRaw(str: []const u8) Text {
        return .{ .raw = str };
    }

    pub fn text(self: Text) []const u8 {
        switch (self) {
            .raw => |r| return r,
        }
    }

    pub fn len(self: Text) usize {
        switch (self) {
            .raw => |r| return r.len,
        }
    }
};

/// Value of runtime-known type.
/// The type is not actually specified, only the value is.
pub const Value = union(enum) {
    int: i64,
    text: Text,
    boolean: bool,
    null: void,

    /// Obtain comptime-known type from a Value.
    pub fn to(comptime T: type, v: Value) Error!T {
        switch (T) {
            i8, i16, i32, i64, u8, u16, u32, u64 => if (v == .int)
                return @intCast(v.int)
            else
                return Error.InvalidType,
            Text => if (v == .text)
                return v.text
            else
                return Error.InvalidType,
            bool => if (v == .boolean)
                return v.boolean
            else
                return Error.InvalidType,
            else => return Error.InvalidType,
        }
    }

    /// Check if type of Value matches given DBType.
    pub fn checkType(v: Value, dbtype: t.DBType) bool {
        if (v == .null) return true;
        switch (dbtype) {
            .any => return true,
            .oid,
            .int1,
            .int2,
            .int4,
            .int8,
            .uint1,
            .uint2,
            .uint4,
            .uint8,
            => return v == .int,
            .text => return v == .text,
            .boolean => return v == .boolean,
        }
    }

    pub const Error = error{InvalidType};

    /// Format the Value as string.
    pub fn format(
        self: Value,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .int => |x| try writer.print("{}", .{x}),
            .text => |s| try writer.print("\"{s}\"", .{s.text()}),
            .boolean => |b| try writer.print("{}", .{b}),
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
            .boolean => return 1,
            .null => return 0,
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
