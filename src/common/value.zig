const std = @import("std");
const t = @import("types.zig");
const oom = @import("utils.zig").oom;

/// Value of runtime-known type.
/// The type is not actually specified, only the value is.
pub const Value = union(enum) {
    int: i64,
    text: []const u8,
    bool: bool,

    /// Obtain comptime-known type from a Value.
    pub fn to(comptime T: type, v: Value) Error!T {
        switch (T) {
            i8, i16, i32, i64, u8, u16, u32, u64 => if (v == .int)
                return @intCast(v.int)
            else
                return Error.InvalidType,
            []const u8 => if (v == .text)
                return v.text
            else
                return Error.InvalidType,
            bool => if (v == .bool)
                return v.bool
            else
                return Error.InvalidType,
            else => return Error.InvalidType,
        }
    }

    /// Check if type of Value matches given DBType.
    pub fn checkType(v: Value, dbtype: t.DBType) bool {
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
            => return v == .int,
            .text => return v == .text,
            .bool => return v == .bool,
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
            .text => |s| try writer.print("\"{s}\"", .{s}),
            .bool => |b| try writer.print("{}", .{b}),
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
            .text => |s| return s.len,
            .bool => return 1,
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
