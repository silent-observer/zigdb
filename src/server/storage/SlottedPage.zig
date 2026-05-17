//! Represents a special slotted page, used in various types of files.
//! The page itself is fixed size (see RawDataFile.zig), however it
//! can contain variable number of items.
//!
//! The page starts with a fixed-size header, containing
//! `count` - the number of items on the page, `used` - the number of used bytes,
//! and custom ExtraHeader.
//! After that `count` pointers follow (each 4 bytes). Each pointer contains
//! an offset and a size (each 2 bytes). THe offset points at the start of
//! an item, counting from the start of the page.
//! The actual item are allocated starting from the *end* of the page,
//! so the space between offset array and the item is always free.
//!
//! To summarize, the page has the following structure:
//! - Header (4+Extra bytes)
//!   - count (2 bytes) - number of tuples on the page
//!   - used (2 bytes) - how many bytes on the page are already used
//!   - extra (Extra bytes) - any given extra header data
//! - Pointers (4*count bytes)
//!   - pointers[0] (4 bytes)
//!   - pointers[1] (4 bytes)
//!   - ...
//!   - pointers[count-1] (4 bytes)
//! - *empty space*
//! - Items (??? bytes)
//!   - Item count-1
//!   - ...
//!   - Item 1
//!   - Item 0
//!
//! Note: it is intentional that a page filled with zeros is a valid
//! heap page containing no items.
//!
//! The actual SlottedPage struct is a representation of a parsed Page.

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
        header: *Header,
        /// Contains `count` offsets for `count` tuples.
        pointers: []ItemPointer,
        page_id: Page.Id,

        pub const Header = extern struct {
            count: u16,
            used_by_data: u16,
            extra: ExtraHeader align(4),
        };

        pub const ItemPointer = extern struct {
            offset: u16,
            size: u16,
        };

        /// Parse a SlottedPage from a raw Page.
        pub fn parse(page: *Page.Data, page_id: Page.Id) Self {
            const h: [*]Header = @ptrCast(&page.d);
            const pointers_ptr: [*]ItemPointer = @ptrCast(&h[1]);
            const pointers = pointers_ptr[0..h[0].count];

            return .{
                .page = page,
                .header = @ptrCast(&page.d),
                .pointers = pointers,
                .page_id = page_id,
            };
        }

        pub fn count(self: *const Self) usize {
            return self.pointers.len;
        }

        /// Get raw data of i-th item on the page.
        pub fn get(self: *const Self, i: usize) []u8 {
            const ptr = self.pointers[i];
            return self.page.d[ptr.offset .. ptr.offset + ptr.size];
        }

        /// Check if a new item would fit on this SlottedPage.
        pub fn fits(self: *const Self, new_len: usize) bool {
            const free = Page.Size -
                @sizeOf(Header) -
                @sizeOf(ItemPointer) * self.header.count -
                self.header.used_by_data;
            return new_len <= free;
        }

        /// Put a new item on this SlottedPage. The pointer is placed at the end of
        /// the pointer array.
        /// Returns the index of the added item.
        pub fn add(self: *Self, data: []const u8) usize {
            self.insert(data, self.pointers.len);
            return self.pointers.len - 1;
        }

        /// Put a new item on this SlottedPage. The pointer is placed at the end of
        /// the pointer array.
        /// Returns the index of the added item.
        pub fn insert(self: *Self, data: []const u8, i: usize) void {
            std.debug.assert(self.fits(data.len));

            // Offset of a last item on the page
            const last_offset = Page.Size - self.header.used_by_data;
            // The offset of the new tuple is *less* than the last one, and
            // the space between them must fit the heap tuple.
            const new_offset = last_offset - data.len;

            @memcpy(self.page.d[new_offset..last_offset], data);
            self.pointers.len += 1;
            if (i != self.pointers.len - 1)
                @memmove(
                    self.pointers[i + 1 .. self.pointers.len],
                    self.pointers[i .. self.pointers.len - 1],
                );
            self.pointers[i] = .{
                .offset = @intCast(new_offset),
                .size = @intCast(data.len),
            };
            self.header.count += 1;
            self.header.used_by_data += @intCast(data.len);
        }
    };
}
