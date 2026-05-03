//! Represents a page of a heap table.
//! The page itself is fixed size (see RawDataFile.zig), however it
//! can contain variable number of heap tuples.
//!
//! The page starts with a fixed-size header, currently only containing
//! `count` - the number of tuples on the page.
//! After that `count` offsets follow (each 2 bytes). Each offset points
//! at the start of a tuple, counting from the start of the page.
//! The actual tuples are allocated starting from the *end* of the page,
//! so the space between offset array and the tuples is always free.
//!
//! To summarize, the page has the following structure:
//! - Header (2 bytes)
//!   - count (2 bytes)
//! - Offsets (2*count bytes)
//!   - offsets[0] (2 bytes)
//!   - offsets[1] (2 bytes)
//!   - ...
//!   - offsets[count-1] (2 bytes)
//! - *empty space*
//! - Tuples (??? bytes)
//!   - Tuple count-1
//!   - ...
//!   - Tuple 1
//!   - Tuple 0
//!
//! Note: it is intentional that a page filled with zeros is a valid
//! heap page containing no tuples.
//!
//! Each heap tuple has a structure similar to MemTuple (see data/tuple.zig).
//! The main difference is that the header contains 2-byte atribute count instead
//! of pointer to tuple descriptor. The structure is the following:
//! - Header (2 bytes)
//!    - count (2 bytes)
//! - Array of offsets (2 * count + 2 bytes)
//!    - offsets[0] (2 bytes)
//!    - offsets[1] (2 bytes)
//!    - offsets[2] (2 bytes)
//!    - ...
//!    - offset[count-1] (2 bytes)
//!    - offset[count] (2 bytes)
//! - Data section (offset[count] bytes)
//!
//! The actual HeapPage struct is a representation of a parsed Page.

const std = @import("std");
const Page = @import("../storage/RawDataFile.zig").Page;
const MemTuple = @import("../data/tuple.zig").MemTuple;
const ids = @import("../ids.zig");
const t = @import("../data/types.zig");
const oom = @import("../utils.zig").oom;

const HeapPage = @This();

const PageHeader = extern struct {
    count: u16,
};

page: *Page.Data,

/// Contains `count` offsets for `count` tuples.
offsets: []u16,
page_id: Page.Id,

/// Parse a HeapPage from a raw Page.
pub fn parse(page: *Page.Data, page_id: Page.Id) HeapPage {
    const h: [*]PageHeader = @ptrCast(&page.d);
    const offsets_ptr: [*]u16 = @ptrCast(&h[1]);
    const offsets = offsets_ptr[0..h[0].count];

    return .{
        .page = page,
        .offsets = offsets,
        .page_id = page_id,
    };
}

pub fn count(self: *const HeapPage) usize {
    return self.offsets.len;
}

fn header(self: *const HeapPage) *PageHeader {
    return @ptrCast(&self.page.d);
}

/// Representation of a on-disk tuple
/// Since heap tuple size is dynamic, all operations with heap tuples
/// must use HeapTuple (the pointer).
const HeapTuple = struct {
    // The tuple pointer is align(1) because no alignment is guaranteed on
    // the actual heap page.
    ptr: *align(1) Data,

    const Header = extern struct {
        count: u16,
        padding: u16 = 0,
        xmin: ids.TransactionId,
        xmax: ids.TransactionId,
    };

    /// Representation of the HeapTuple data.
    /// Note that the actual size of HeapTuple is in general
    /// bigger than @sizeOf(Data).
    const Data = extern struct {
        h: Header,
        // Dummy field to represent array of offsets:
        // actually contains N+1 offsets for N attributes.
        // The last offset points after the whole array of data.
        offsets_start: [1]u16,
    };

    /// Parsed HeapTuple, containing all the pointers to the relevant
    /// sections of the HeapTuple.
    pub const Details = struct {
        h: *align(1) Header,
        offsets: []align(1) u16,
        data: []u8,
    };

    /// Parse HeapTuple and obtain its internal details.
    /// Should only really be used internally to convert
    /// between tuple representations.
    pub fn details(self: HeapTuple) Details {
        const n = self.ptr.h.count;
        const offsets: [*]align(1) u16 = @ptrCast(&self.ptr.offsets_start);
        const data: [*]u8 = @ptrCast(&offsets[n + 1]);
        return .{
            .h = &self.ptr.h,
            .offsets = offsets[0 .. n + 1],
            .data = data[0..offsets[n]],
        };
    }

    /// Total size of a HeapTuple (on disk).
    fn heapSize(self: HeapTuple) usize {
        const d = self.details();
        return @sizeOf(HeapTuple.Header) +
            d.offsets.len * @sizeOf(u16) +
            d.data.len;
    }

    /// Deserialize a MemTuple from HeapTuple.
    /// The MemTuple is allocated with a given Allocator.
    /// The TupleDescriptor must also be supplied.
    fn read(
        self: HeapTuple,
        descr: *const t.TupleDescriptor,
        alloc: std.mem.Allocator,
        pos: MemTuple.Pos,
    ) MemTuple {
        std.debug.assert(descr.has_extended);
        std.debug.assert(self.ptr.h.count == descr.attrs.len);
        const d = self.details();
        const mem_tuple_size = @sizeOf(MemTuple.Header) +
            @sizeOf(MemTuple.ExtendedFields) +
            d.offsets.len * @sizeOf(u16) +
            d.data.len;

        // The MemTuple must be aligned.
        const buf = alloc.alignedAlloc(
            u8,
            std.mem.Alignment.fromByteUnits(@alignOf(MemTuple.Header)),
            mem_tuple_size,
        ) catch oom();
        const mem_tuple: MemTuple = .{ .ptr = @ptrCast(&buf[0]) };
        mem_tuple.ptr.h.descr = descr;

        // Copy the actual offsets and data to the MemTuple.
        const dest_offsets_ptr: [*]u16 = @ptrCast(&mem_tuple.ptr.tail.extended.offsets_start);
        const dest_data_ptr: [*]u8 = @ptrCast(&dest_offsets_ptr[self.ptr.h.count + 1]);
        @memcpy(dest_offsets_ptr, d.offsets);
        @memcpy(dest_data_ptr, d.data);

        // Fill extended fields
        mem_tuple.ptr.tail.extended.ext = .{
            .xmin = self.ptr.h.xmin,
            .xmax = self.ptr.h.xmax,
            .pos = pos,
        };

        return mem_tuple;
    }

    /// Calculate the expected size of a MemTuple if it's written onto disk.
    fn expectedSize(mem: MemTuple) usize {
        const d = mem.details();
        return @sizeOf(HeapTuple.Header) +
            d.offsets.len * @sizeOf(u16) +
            d.data.len;
    }

    /// Serialize a MemTuple as a HeapTuple.
    /// The destination must have exact amount of space to fit the tuple.
    /// That can be calculated with expectedSize()
    /// pos extended field is ignored.
    fn write(mem: MemTuple, dest: []u8) void {
        // Ensure the size matches
        std.debug.assert(dest.len == expectedSize(mem));
        const d = mem.details();
        const mem_len = mem.len();

        const dest_tuple: HeapTuple = .{ .ptr = @ptrCast(dest) };
        dest_tuple.ptr.h = .{
            .count = @intCast(mem_len),
            .xmin = mem.ptr.tail.extended.ext.xmin,
            .xmax = mem.ptr.tail.extended.ext.xmax,
        };

        const dest_offsets_ptr: [*]align(1) u16 = @ptrCast(&dest_tuple.ptr.offsets_start);
        const dest_data_ptr: [*]align(1) u8 = @ptrCast(&dest_offsets_ptr[mem_len + 1]);
        @memcpy(dest_offsets_ptr, d.offsets);
        @memcpy(dest_data_ptr, d.data);
    }
};

/// Get pointer to raw data of i-th tuple on the page.
fn getHeapTuple(self: *const HeapPage, i: u16) HeapTuple {
    return .{ .ptr = @ptrCast(&self.page.d[self.offsets[i]]) };
}

/// Read i-th tuple from HeapPage into a MemTuple.
/// The MemTuple is allocated with a given Allocator.
/// The TupleDescriptor must also be supplied.
pub fn read(
    self: *const HeapPage,
    i: u16,
    descr: *const t.TupleDescriptor,
    alloc: std.mem.Allocator,
) MemTuple {
    const tuple = self.getHeapTuple(i);
    return tuple.read(descr, alloc, .{
        .page_id = self.page_id,
        .index = i,
    });
}

/// Check if i-th tuple on HeapPage can be updated with a new MemTuple.
/// This can be done if the new data fits into the space currently taken
/// by old data.
pub fn canUpdateInPlace(
    self: *const HeapPage,
    i: u16,
    new: MemTuple,
) bool {
    const tuple = self.getHeapTuple(i);
    return HeapTuple.expectedSize(new) <= tuple.heapSize();
}

/// Check if a new MemTuple would fit on this HeapPage.
pub fn fits(self: *const HeapPage, tuple: MemTuple) bool {
    // Offset of a last tuple on the page
    const last_offset = if (self.offsets.len == 0)
        Page.Size
    else
        self.offsets[self.offsets.len - 1];

    const header_size = @sizeOf(PageHeader) + self.offsets.len * @sizeOf(u16);
    return header_size + @sizeOf(u16) <= last_offset - HeapTuple.expectedSize(tuple);
}

/// Put a new MemTuple on this HeapPage. The offset is placed at the end of
/// the offset array.
/// pos extended field in MemTuple is ignored.
/// Returns the index of the added tuple.
pub fn add(self: *HeapPage, tuple: MemTuple) u16 {
    std.debug.assert(self.fits(tuple));
    std.debug.assert(tuple.ptr.h.descr.has_extended);

    // Offset of a last tuple on the page
    const last_offset = if (self.offsets.len == 0)
        Page.Size
    else
        self.offsets[self.offsets.len - 1];
    // The offset of the new tuple is *less* than the last one, and
    // the space between them must fit the heap tuple.
    const new_offset = last_offset - HeapTuple.expectedSize(tuple);

    HeapTuple.write(tuple, self.page.d[new_offset..last_offset]);
    self.offsets.len += 1;
    self.offsets[self.offsets.len - 1] = @intCast(new_offset);
    self.header().count += 1;
    return @intCast(self.offsets.len - 1);
}

/// Update the i-th tuple on HeapPage with a new MemTuple.
/// This can be done if the new data fits into the space currently taken
/// by old data, which can be checked with canUpdateInPlace.
pub fn updateInPlace(self: *HeapPage, i: u16, new: MemTuple) void {
    std.debug.assert(self.canUpdateInPlace(i, new));
    std.debug.assert(new.ptr.h.descr.has_extended);
    const tuple = self.getHeapTuple(i);
    const raw: [*]u8 = @ptrCast(tuple.ptr);
    // The space currently occupied by the tuple.
    const dest = raw[0..tuple.heapSize()];
    @memset(dest, 0);
    HeapTuple.write(new, dest);
}

/// Deletes the i-th tuple on HeapPage.
/// This updates tuple's xmax to tid.
pub fn deleteTupleAt(self: *HeapPage, i: u16, tid: ids.TransactionId) void {
    const tuple = self.getHeapTuple(i);
    tuple.ptr.h.xmax = tid;
}
