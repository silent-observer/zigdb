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

    /// Parse Text value from raw bytes
    pub fn fromBytes(bytes: []const u8) Text {
        return switch (bytes[0]) {
            0x00 => .{ .raw = bytes[1..] },
            0x01 => .{ .toast = std.mem.bytesToValue(
                Toast,
                bytes[1..],
            ) },
            else => unreachable,
        };
    }

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

    fn read(
        r: *std.Io.Reader,
        alloc: std.mem.Allocator,
    ) !Text {
        const size = try r.takeLeb128(i32);
        if (size >= 0) {
            return makeRaw(r.readAlloc(alloc, @intCast(size)) catch oom());
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

    fn write(
        self: *const Text,
        w: *std.Io.Writer,
    ) !void {
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
};

/// Value of runtime-known type.
/// The type is not actually specified, only the value is.
pub const Value = union(enum) {
    int: i64,
    text: Text,
    boolean: bool,
    uuid: uuid.Uuid,
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
            uuid.Uuid => if (v == .uuid)
                return v.uuid
            else
                return Error.InvalidType,
            else => return Error.InvalidType,
        }
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
            .uuid => return 36,
            .null => return 0,
        }
    }

    pub fn read(
        r: *std.Io.Reader,
        dbtype: t.DBType,
        alloc: std.mem.Allocator,
    ) !Value {
        switch (dbtype) {
            .uint1 => return .{ .int = @intCast(try r.takeInt(u8, .little)) },
            .uint2 => return .{ .int = @intCast(try r.takeInt(u16, .little)) },
            .uint4, .serial => return .{ .int = @intCast(try r.takeInt(u32, .little)) },
            .uint8, .oid => return .{ .int = @intCast(try r.takeInt(u64, .little)) },
            .int1 => return .{ .int = @intCast(try r.takeInt(u8, .little)) },
            .int2 => return .{ .int = @intCast(try r.takeInt(u16, .little)) },
            .int4 => return .{ .int = @intCast(try r.takeInt(u32, .little)) },
            .int8 => return .{ .int = @intCast(try r.takeInt(u64, .little)) },
            .uuid => return .{ .int = @intCast(try r.takeInt(uuid.Uuid, .little)) },
            .boolean => return .{ .boolean = try r.takeByte() != 0 },
            .nulltype => return .null,
            .text, .long_text => return .{ .text = try Text.read(r, alloc) },
        }
    }

    pub fn write(
        self: Value,
        dbtype: t.DBType,
        w: *std.Io.Writer,
    ) !void {
        if (self == .null) return;
        switch (dbtype) {
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
            .text, .long_text => try self.text.write(w),
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
