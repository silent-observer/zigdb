//! Two main representation of tuples.
//! MemTuple is the convenient representation in memory, useful for various
//! computations. CompactTuple is a compact on-disk representation, useful
//! for representing MemTuple in a serialized way.
//!
//! The basic structure is as follows:
//! - Header (8 bytes)
//!    - pointer to TupleDescrptor (8 bytes)
//! - Extended fields (16 bytes) - optional!
//!    - xmin (4 bytes) - ID of a transaction that inserted this tuple.
//!    - xmax (4 bytes) - ID of a transaction that deleted this tuple.
//!    - pos (8 bytes) - Position of the tuple in a table
//!        - page_id (4 bytes) - Page number in the file
//!        - index (2 bytes) - Index of a tuple on a page
//!        - padding (2 bytes)
//! - Array of offsets (2 * N + 2 bytes)
//!    - offsets[0] (2 bytes)
//!    - offsets[1] (2 bytes)
//!    - offsets[2] (2 bytes)
//!    - ...
//!    - offset[N-1] (2 bytes)
//!    - offset[N] (2 bytes)
//! - Data section (offset[N] bytes)
//!
//! where N is the number of attributes in the TupleDescriptor.
//! The presence or absence of extended fields is determined by
//! has_extended flag in the TupleDescriptor.
//!
//! The data in the tuple is stored sequentially after the array of offsets.
//! The first N offsets contain the offset of the N attributes, counting from
//! the start of data section.
//! The last offset (N+1's) contains the total size of the data in the tuple.
//! This means that i-th attribute in the data spans from offset[i] to
//! offset[i+1] (exclusive).
//!
//! Example:
//! The tuple descriptor contains 3 columns of types (int4, text, bool).
//! The tuple contains values [1234, "hello!", true].
//! The sizes of the values are then 4 bytes, 6 bytes, 1 byte, or 11 bytes in total.
//! This tuple is represented in memory like this:
//!
//! ```
//! +-------------------------------+
//! |  Pointer to TupleDescriptor   | Header (8 bytes)
//! +-------------------------------+
//! |   0   |   4   |   10  |   11  | Offsets (2 * 4 = 8 bytes)
//! +-------------------------------+
//! |      1234     | h | e | l | l |
//! +-------------------------------+
//! | o | ! | 1 |                     Data (4 + 6 + 1 = 11 bytes)
//! +-----------+
//! ```
//! Operations on a tuple stored in the heap table.
//! The page itself is fixed size (see RawDataFile.zig), however it
//! can contain variable number of heap tuples.
//!
//! Each heap tuple has the following structure:
//! - Header (8 bytes)
//!    - xmin (4 bytes) - ID of transaction that inserted this tuple
//!    - xmax (4 bytes) - ID of transaction that deleted this tuple
//! - NULL bitmask (ceil(N/8) bytes) - bitmask describing NULL fields in the tuple
//! - Data section (??? bytes)
//!
//! NULL bitmask contains 1 byte for each 8 attributes (so usually just 1-2 bytes),
//! and each bit corresponds to an attribute. It is set if the value is NULL.
//! The data section contains the serialized not NULL attributes one after another.

const std = @import("std");
const builtin = @import("builtin");
const native_endian = builtin.target.cpu.arch.endian();

const ids = @import("ids.zig");
const types = @import("types.zig");
const TupleDescriptor = types.TupleDescriptor;
const DBType = types.DBType;
const value = @import("value.zig");
const Value = value.Value;
const Text = value.Text;
const oom = @import("utils.zig").oom;

const uuid = @import("uuid");

/// In-memory representation of a tuple.
/// It simply contains a slice of Values and possibly some extended fields.
/// This simplifies all operations on MemTuples.
/// Additionally it always contains a pointer to (possibly shared) TupleDescriptor,
/// containing all the types of values in the MemTuple.
pub const MemTuple = struct {
    descr: *const TupleDescriptor,
    ext: ?*ExtendedFields,
    values: []Value,

    /// Additional fields taken from heap table.
    pub const ExtendedFields = extern struct {
        xmin: ids.RealTransactionId, // Transaction that inserted this tuple
        xmax: ids.RealTransactionId, // Transaction that deleted this tuple
        pos: Pos = undefined, // Position of the tuple in the table
    };

    /// Position of a tuple in a table.
    /// Is enough to identify a specific tuple, but could change
    /// after any table updates.
    pub const Pos = extern struct {
        page_id: ids.PageId,
        index: u16,
        padding: [2]u8 = .{ 0, 0 },

        pub const none = Pos{
            .page_id = 0,
            .index = 0,
        };
    };

    /// Deinitialize the MemTuple. Simply deinits all the values one
    /// by one, and then the whole value slice and extended fields,
    /// if those are present.
    pub fn deinit(self: MemTuple, alloc: std.mem.Allocator) void {
        for (self.values) |v|
            v.deinit(alloc);
        alloc.free(self.values);
        if (self.ext) |e|
            alloc.destroy(e);
    }

    /// Number of attributes in the MemTuple.
    pub fn len(self: MemTuple) usize {
        return self.values.len;
    }

    /// Format the MemTuple like [1234, "hello!", true].
    pub fn format(
        self: MemTuple,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.writeAll("[");
        for (self.values, 0..) |v, i| {
            if (i > 0)
                try writer.writeAll(", ");
            try writer.print("{f}", .{v});
        }
        try writer.writeAll("]");
    }

    /// Format the MemTuple as a JSON array.
    pub fn jsonStringify(self: MemTuple, jws: anytype) !void {
        try jws.beginArray();
        for (self.values) |v|
            try jws.write(v);
        try jws.endArray();
    }

    /// Construct a newly allocated tuple from raw parts.
    /// All the data is copied into the new allocator.
    /// You can construct the MemTuple directly if you don't need this.
    pub fn make(
        descr: *const TupleDescriptor,
        ext: ?*const ExtendedFields,
        values: []const Value,
        alloc: std.mem.Allocator,
    ) MemTuple {
        const values_ptr = alloc.dupe(Value, values) catch oom();
        for (values_ptr) |*v|
            v.* = v.clone(alloc);

        var ext_ptr: ?*ExtendedFields = null;
        if (ext) |e| {
            ext_ptr = alloc.create(ExtendedFields) catch oom();
            ext_ptr.?.* = e.*;
        }

        return .{
            .descr = descr,
            .ext = ext_ptr,
            .values = values_ptr,
        };
    }

    /// Clones the tuple into a new allocator. Also clones all the values.
    pub fn clone(self: MemTuple, alloc: std.mem.Allocator) MemTuple {
        return make(self.descr, self.ext, self.values, alloc);
    }
};

/// Tuple stored in a compact format.
/// The page itself is fixed size (see RawDataFile.zig), however it
/// can contain variable number of heap tuples.
/// The compact tuple may have an additional (struct) header, depending
/// on the application.
///
/// Each compact tuple has the following structure:
/// - Header (fixed number of bytes)
/// - NULL bitmask (ceil(N/8) bytes) - bitmask describing NULL fields in the tuple
/// - Data section (??? bytes)
///
/// NULL bitmask contains 1 byte for each 8 attributes (so usually just 1-2 bytes),
/// and each bit corresponds to an attribute. It is set if the value is NULL.
/// The data section contains the serialized not NULL attributes one after another.
pub fn CompactTuple(comptime Header: type) type {
    return struct {
        const Self = @This();

        /// Compact tuple is stored as a raw slice of bytes.
        data: []u8,

        /// Actual data stored in the tuple, in convenient form.
        pub const Uncompacted = struct {
            header: Header,
            values: []Value,
        };

        /// Uncompact a tuple, reading its data into usable form.
        pub fn uncompact(
            self: Self,
            descr: *const TupleDescriptor,
            alloc: std.mem.Allocator,
        ) !Uncompacted {
            var reader = std.Io.Reader.fixed(self.data);
            return read(&reader, descr, alloc);
        }

        /// Compact a tuple, packing the data into compact form.
        pub fn compact(
            data: Uncompacted,
            descr: *const TupleDescriptor,
            alloc: std.mem.Allocator,
        ) Self {
            var writer = std.Io.Writer.Allocating.init(alloc);
            write(&writer.writer, data, descr) catch oom();
            return .{ .data = writer.toOwnedSlice() catch oom() };
        }

        /// Read the compact tuple from binary data into a usable form.
        pub fn read(
            r: *std.Io.Reader,
            descr: *const TupleDescriptor,
            alloc: std.mem.Allocator,
        ) !Uncompacted {
            const header = if (Header == void)
                void{}
            else
                try r.takeStruct(Header, .little);

            const null_bytes_count = std.math.divCeil(
                usize,
                descr.len(),
                8,
            ) catch unreachable;
            const null_bytes = r.readAlloc(alloc, null_bytes_count) catch oom();
            defer alloc.free(null_bytes);

            var vals = std.ArrayList(Value)
                .initCapacity(alloc, descr.len()) catch oom();
            for (descr.attrs.items, 0..) |att, i| {
                const byte_idx = i / 8;
                const bit_shift: u3 = @intCast(i % 8);
                const is_null = ((null_bytes[byte_idx] >> bit_shift) & 1) != 0;

                if (is_null)
                    vals.appendAssumeCapacity(.null)
                else {
                    const val = try Value.read(r, att.t);
                    vals.appendAssumeCapacity(val.clone(alloc));
                }
            }
            return .{
                .header = header,
                .values = vals.toOwnedSliceAssert(),
            };
        }

        /// Write the data as a compact tuple.
        pub fn write(
            w: *std.Io.Writer,
            data: Uncompacted,
            descr: *const TupleDescriptor,
        ) !void {
            std.debug.assert(data.values.len == descr.len());

            if (Header != void)
                try w.writeStruct(data.header, .little);

            var null_byte: u8 = 0;
            for (0..descr.len()) |i| {
                const v = data.values[i];
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
                const v = data.values[i];
                try v.write(att.t, w);
            }
        }

        /// Read the fixed-size header without parsing tuple values
        pub inline fn getHeader(self: Self) Header {
            const ptr: *align(1) Header = @ptrCast(self.data.ptr);
            var header = ptr.*;
            if (native_endian != .little)
                std.mem.byteSwapAllFields(Header, &header);
            return header;
        }

        /// Write the fixed-size header without parsing tuple values
        pub inline fn setHeader(self: Self, h: Header) void {
            const ptr: *align(1) Header = @ptrCast(self.data.ptr);
            ptr.* = h;
            if (native_endian != .little)
                std.mem.byteSwapAllFields(Header, ptr);
        }
    };
}
