//! Representation of an arbitrary tuple, as stored in memory
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

const std = @import("std");
const uuid = @import("uuid");
const ids = @import("ids.zig");
const t = @import("types.zig");
const value = @import("value.zig");
const Value = value.Value;
const Text = value.Text;
const oom = @import("utils.zig").oom;

/// Pointer to a memory tuple
/// Since memory tuple size is dynamic, all operations with memory tuples
/// must use MemTuple (the pointer).
pub const MemTuple = struct {
    ptr: *Data,

    pub const Header = extern struct {
        descr: *const t.TupleDescriptor,
    };

    /// Additional fields taken from heap table.
    pub const ExtendedFields = extern struct {
        xmin: ids.RealTransactionId, // Transaction that inserted this tuple
        xmax: ids.RealTransactionId, // Transaction that deleted this tuple
        pos: Pos, // Position of the tuple in the table
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

    /// Representation of the memory tuple data.
    /// Note that the actual size of memory tuple is in general
    /// bigger than @sizeOf(Data).
    pub const Data = extern struct {
        h: Header,
        tail: extern union {
            // This has two versions: without extended fields or with them
            normal: Normal,
            extended: Extended,
        },

        pub const Normal = extern struct {
            // Dummy field to represent array of offsets:
            // actually contains N+1 offsets for N attributes.
            // The last offset points after the whole array of data.
            offsets_start: [1]u16,
        };

        pub const Extended = extern struct {
            // Optional extended fields
            ext: ExtendedFields,
            // Dummy field to represent array of offsets:
            // actually contains N+1 offsets for N attributes.
            // The last offset points after the whole array of data.
            offsets_start: [1]u16,
        };
    };

    /// Parsed MemTuple, containing all the pointers to the relevant
    /// sections of the MemTuple.
    pub const Details = struct {
        h: *Header,
        ext: ?*ExtendedFields,
        offsets: []u16,
        data: []u8,
    };

    /// Parse MemTuple and obtain its internal details.
    /// Should only really be used internally to convert
    /// between tuple representations.
    pub inline fn details(self: MemTuple) Details {
        const n = self.len();
        const has_ext = self.ptr.h.descr.has_extended;

        const offsets: [*]u16 = if (has_ext)
            @ptrCast(&self.ptr.tail.extended.offsets_start)
        else
            @ptrCast(&self.ptr.tail.normal.offsets_start);

        const ext = if (has_ext) &self.ptr.tail.extended.ext else null;
        const data: [*]u8 = @ptrCast(&offsets[n + 1]);
        return .{
            .h = &self.ptr.h,
            .ext = ext,
            .offsets = offsets[0 .. n + 1],
            .data = data[0..offsets[n]],
        };
    }

    /// Number of attributes in the MemTuple.
    pub fn len(self: MemTuple) usize {
        return self.ptr.h.descr.len();
    }

    /// Type of i-th attribute in the MemTuple.
    pub fn dbtype(self: MemTuple, i: usize) t.DBType {
        return self.ptr.h.descr.attrs.items[i].t;
    }

    /// Format the MemTuple like [1234, "hello!", true].
    pub fn format(
        self: MemTuple,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.writeAll("[");
        for (0..self.len()) |i| {
            if (i > 0)
                try writer.writeAll(", ");
            try writer.print("{f}", .{self.getValue(i)});
        }
        try writer.writeAll("]");
    }

    /// Format the MemTuple as a JSON array.
    pub fn jsonStringify(self: MemTuple, jws: anytype) !void {
        try jws.beginArray();
        for (0..self.len()) |i|
            try jws.write(self.getValue(i));
        try jws.endArray();
    }

    /// Pointer to an i-th offset (in the offset array).
    fn offsetPtr(self: MemTuple, i: usize) *u16 {
        const d = self.details();
        return &d.offsets[i];
    }

    /// Byte slice of the i-th attribute data.
    fn dataPtr(self: MemTuple, i: usize) []u8 {
        const d = self.details();
        const start = d.offsets[i];
        const end = d.offsets[i + 1];
        return d.data[start..end];
    }

    /// Access extended fields in this tuple (assume they exist).
    pub fn extended(self: MemTuple) *MemTuple.ExtendedFields {
        return self.details().ext.?;
    }

    /// Total size of a MemTuple (including header, offset array and actual data).
    pub fn size(self: MemTuple) usize {
        const d = self.details();
        return @sizeOf(MemTuple.Header) +
            @as(usize, if (d.ext != null) @sizeOf(MemTuple.ExtendedFields) else 0) +
            d.offsets.len * @sizeOf(u16) +
            d.data.len;
    }

    /// Allocate enough space for the tuple (without initializing anything).
    /// Ensures correct alignment.
    pub fn allocUnitialized(alloc: std.mem.Allocator, s: usize) MemTuple {
        const bytes = alloc.alignedAlloc(
            u8,
            std.mem.Alignment.fromByteUnits(@alignOf(MemTuple.Data)),
            s,
        ) catch oom();
        return .{ .ptr = @ptrCast(bytes) };
    }

    /// Clones the tuple into a new allocator.
    /// Ensures correct alignment.
    pub fn clone(self: MemTuple, alloc: std.mem.Allocator) MemTuple {
        const s = self.size();
        const bytes = alloc.alignedAlloc(
            u8,
            std.mem.Alignment.fromByteUnits(@alignOf(MemTuple.Data)),
            s,
        ) catch oom();
        @memcpy(bytes, @as([*]u8, @ptrCast(self.ptr)));
        return .{ .ptr = @ptrCast(bytes) };
    }

    /// Get i-th attribute with a runtime-known type.
    pub fn getValue(self: MemTuple, i: usize) Value {
        const data: []const u8 = self.dataPtr(i);
        var r = std.Io.Reader.fixed(data);
        if (data.len == 0)
            return .null;
        return Value.read(&r, self.dbtype(i)) catch unreachable;
    }

    /// Set i-th attribute with a comptime-known type T.
    /// Danger: only values of fixed size are directly settable.
    pub fn set(self: MemTuple, T: type, i: usize, val: T) void {
        const data = self.dataPtr(i);
        std.debug.assert(self.dbtype(i).checkType(T));
        return switch (T) {
            u8, u16, u32, u64, i8, i16, i32, i64, bool => std.mem.bytesAsValue(T, data).* = val,
            Text => comptime unreachable,
            else => comptime unreachable,
        };
    }

    /// Set i-th attribute with a runtime-known type.
    /// Danger: only values of fixed size are directly settable.
    pub fn setValue(self: MemTuple, i: usize, val: Value) void {
        const data: []const u8 = @constCast(self).dataPtr(i);
        std.debug.assert(val.checkType(self.dbtype(i)));
        return switch (self.dbtype(i)) {
            .int1 => std.mem.bytesAsValue(i8, data).* = @intCast(val.int),
            .int2 => std.mem.bytesAsValue(i16, data).* = @intCast(val.int),
            .int4 => std.mem.bytesAsValue(i32, data).* = @intCast(val.int),
            .int8 => std.mem.bytesAsValue(i64, data).* = @intCast(val.int),
            .uint1 => std.mem.bytesAsValue(u8, data).* = @intCast(val.int),
            .uint2 => std.mem.bytesAsValue(u16, data).* = @intCast(val.int),
            .uint4, .oid => std.mem.bytesAsValue(u32, data).* = @intCast(val.int),
            .uint8 => std.mem.bytesAsValue(u64, data).* = @intCast(val.int),
            .boolean => std.mem.bytesAsValue(bool, data).* = val.boolean,
            .text, .long_text => unreachable,
        };
    }

    /// Free memory of a MemTuple.
    /// Special function must be used because of alignment issues.
    pub fn deinit(self: MemTuple, alloc: std.mem.Allocator) void {
        const ptr: [*]align(@alignOf(MemTuple.Data)) u8 = @ptrCast(self.ptr);
        const slice = ptr[0..self.size()];
        alloc.free(slice);
    }

    /// Helper struct for building new MemTuples.
    /// Use this whenever you want to create a MemTuple.
    pub const Builder = struct {
        gpa: std.mem.Allocator, // Allocator used for the MemTuple
        writer: std.Io.Writer.Allocating, // Actual data represented as array of bytes
        offset: u16, // Current data offset
        index: usize, // Current attribute index
        extended: bool, // Did we add extended fields?

        /// Current tuple (still in construction)
        fn tuple(b: *Builder) MemTuple {
            return .{ .ptr = @ptrCast(@alignCast(b.writer.written().ptr)) };
        }

        /// Initialize a new builder. TupleDescriptor must be given immediately.
        pub fn init(gpa: std.mem.Allocator, descr: *const t.TupleDescriptor) Builder {
            // Array is initialized with approximate capacity.
            var writer = std.Io.Writer.Allocating.initAligned(
                gpa,
                .fromByteUnits(@alignOf(MemTuple.Data)),
            );
            writer.writer.writeStruct(
                Header{ .descr = descr },
                .native,
            ) catch oom();

            if (descr.has_extended)
                _ = writer.writer.splatByteAll(0xAA, @sizeOf(ExtendedFields)) catch oom();
            writer.writer.writeInt(u16, 0, .native) catch oom();
            _ = writer.writer.splatByteAll(0xAA, descr.len() * @sizeOf(u16)) catch oom();

            return .{
                .gpa = gpa,
                .writer = writer,
                .offset = 0,
                .index = 0,
                .extended = false,
            };
        }

        /// Push a byte slice into the data section.
        fn pushBytes(b: *Builder, bytes: []const u8) void {
            b.offset += @intCast(bytes.len);
            b.index += 1;
            std.debug.assert(b.index <= b.tuple().len());
            b.tuple().offsetPtr(b.index).* = b.offset; // Update offset array
            b.writer.writer.writeAll(bytes) catch oom();
        }

        /// Push a Text value into the data section.
        fn pushText(b: *Builder, text: Text) void {
            const start = b.writer.writer.end;
            text.write(&b.writer.writer) catch oom();
            const end = b.writer.writer.end;
            b.offset += @intCast(end - start);
            b.index += 1;
            std.debug.assert(b.index <= b.tuple().len());
            b.tuple().offsetPtr(b.index).* = b.offset; // Update offset array
        }

        /// Push a value of runtime-known type.
        /// The type still has to match the one given in the tuple descriptor.
        pub fn pushValue(b: *Builder, val: Value) void {
            const i = b.index;
            std.debug.assert(i < b.tuple().len());
            if (val == .null) {
                // Special case for NULLs
                b.pushBytes(&.{});
                return;
            }
            std.debug.assert(val.checkType(b.tuple().dbtype(i)));

            const start = b.writer.writer.end;
            val.write(b.tuple().dbtype(i), &b.writer.writer) catch oom();
            const end = b.writer.writer.end;
            b.offset += @intCast(end - start);
            b.index += 1;
            std.debug.assert(b.index <= b.tuple().len());
            b.tuple().offsetPtr(b.index).* = b.offset; // Update offset array
        }

        /// Adds extended fields to the tuple.
        pub fn addExtended(b: *Builder, ext: MemTuple.ExtendedFields) void {
            std.debug.assert(b.tuple().ptr.h.descr.has_extended);
            b.tuple().ptr.tail.extended.ext = ext;
            b.extended = true;
        }

        /// Obtain the finished tuple from the builder.
        /// The builder is then done and no deinit is needed.
        pub fn finalize(b: *Builder) MemTuple {
            // The tuple must actually be finished
            std.debug.assert(b.index == b.tuple().len());
            if (b.tuple().ptr.h.descr.has_extended)
                std.debug.assert(b.extended);
            const data = b.writer.toOwnedSlice() catch oom();
            return .{ .ptr = @ptrCast(@alignCast(data.ptr)) };
        }
    };
};
