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
//!   - count (2 bytes) - number of tuples on the page
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
//! - Header (12 bytes)
//!    - count (2 bytes) - number of attributes
//!    - padding (2 bytes)
//!    - xmin (4 bytes) - ID of transaction that inserted this tuple
//!    - xmax (4 bytes) - ID of transaction that deleted this tuple
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
const Page = @import("RawDataFile.zig").Page;
const common = @import("common");
const MemTuple = common.MemTuple;
const TupleDescriptor = common.TupleDescriptor;
const oom = common.oom;
const ids = common.ids;

pub fn SlottedPage(comptime ExtraHeader: type) type {
    return struct {
        const Self = @This();

        page: *Page.Data,
        /// Contains `count` offsets for `count` tuples.
        pointers: []ItemPointer,
        page_id: Page.Id,

        pub const Header = extern struct {
            count: u16,
            free: u16,
            extra: ExtraHeader align(4),
        };

        pub const ItemPointer = extern struct {
            offset: u16,
            size: u16,
        };

        pub fn writeInit(page: *Page.Data, extra: ExtraHeader) void {
            @memset(&page.d, 0);
            const h: *Header = @ptrCast(&page.d);
            h.count = 0;
            h.extra = extra;
            h.free = Page.Size - @sizeOf(Header);
        }

        /// Parse a SlottedPage from a raw Page.
        pub fn parse(page: *Page.Data, page_id: Page.Id) Self {
            const h: [*]Header = @ptrCast(&page.d);
            const pointers_ptr: [*]ItemPointer = @ptrCast(&h[1]);
            const pointers = pointers_ptr[0..h[0].count];

            return .{
                .page = page,
                .pointers = pointers,
                .page_id = page_id,
            };
        }

        pub fn count(self: *const Self) usize {
            return self.pointers.len;
        }

        pub fn header(self: *const Self) *Header {
            return @ptrCast(&self.page.d);
        }

        /// Get raw data of i-th item on the page.
        pub fn get(self: *const Self, i: u16) []u8 {
            const ptr = self.pointers[i];
            return self.page.d[ptr.offset .. ptr.offset + ptr.size];
        }

        /// Check if a new item would fit on this SlottedPage.
        pub fn fits(self: *const Self, new_len: usize) bool {
            return new_len <= self.header().free;
        }

        /// Put a new item on this SlottedPage. The pointer is placed at the end of
        /// the pointer array.
        /// Returns the index of the added item.
        pub fn add(self: *Self, data: []const u8) u16 {
            std.debug.assert(self.fits(data.len));

            // Offset of a last item on the page
            const last_offset = if (self.pointers.len == 0)
                Page.Size
            else
                self.pointers[self.pointers.len - 1].offset;
            // The offset of the new tuple is *less* than the last one, and
            // the space between them must fit the heap tuple.
            const new_offset = last_offset - data.len;

            @memcpy(self.page.d[new_offset..last_offset], data);
            self.pointers.len += 1;
            self.pointers[self.pointers.len - 1] = .{
                .offset = @intCast(new_offset),
                .size = @intCast(data.len),
            };
            self.header().count += 1;
            self.header().free -= @intCast(data.len + @sizeOf(ItemPointer));
            return @intCast(self.pointers.len - 1);
        }
    };
}
