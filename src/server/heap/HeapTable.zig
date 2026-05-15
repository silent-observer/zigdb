//! Represents a whole heap table.
//!
//! The heap table occupies a single data file (split into pages).
//! The 0th page is always the header page, containing the metadata of the table.
//! The next pages are HeapPages, containing the actual tuples.

const std = @import("std");

const storage = @import("../storage.zig");
const Page = storage.Page;
const common = @import("common");
const MemTuple = common.MemTuple;
const ids = common.ids;

const HeapTable = @This();

pub const HeapTuple = common.CompactTuple(TupleHeader);
pub const HeapPage = storage.SlottedPage(void);

cache: *storage.Cache,
table_id: ids.FullTableId,

const TupleHeader = extern struct {
    xmin: ids.RealTransactionId,
    xmax: ids.RealTransactionId,
};

/// The fixed-size header, placed at the start of the 0th page.
const FileHeader = extern struct {
    // 8-byte magic number to identify the file type
    magic_value: [8]u8 = Magic,
    // Id of the table
    table_id: ids.FullTableId,
    // Total number of pages in the table (including the header page)
    pages: u16,
    // Reserved space
    padding: [6]u8 = std.mem.zeroes([6]u8),
    // Counter for a SERIAL field
    serial_counter: std.atomic.Value(u64),

    const Magic: [8]u8 = .{ 'Z', 'D', 'B', '_', 'H', 'E', 'A', 'P' };

    /// Obtain a header from raw page (and check the magic number)
    pub fn fromPage(page: *Page.Data) *FileHeader {
        const h: *FileHeader = @ptrCast(page);
        std.debug.assert(std.meta.eql(h.magic_value, Magic));
        std.debug.assert(h.pages > 0);
        return h;
    }

    /// Write the header page
    pub fn writePage(h: *const FileHeader, page: *Page.Data) void {
        @memset(&page.d, 0);
        const dest: *FileHeader = @ptrCast(&page.d);
        dest.* = h.*;
    }
};

/// Initializes a heap table handle.
/// Does not actually write anything to disk.
pub fn init(cache: *storage.Cache, table_id: ids.FullTableId) HeapTable {
    return .{
        .cache = cache,
        .table_id = table_id,
    };
}

/// Create a file for a new heap table.
/// Only initializes its 0th page.
pub fn create(self: HeapTable) !void {
    const page = try self.cache.getWriteable(.{
        .file = self.table_id.fullFileId(),
        .page = 0,
    });
    defer self.cache.unpin(page);

    const header = FileHeader{
        .table_id = self.table_id,
        .pages = 1,
        .serial_counter = .init(0),
    };
    header.writePage(page.page);
}

/// Truncation is actually equivalent to creating a new heap table.
pub fn truncate(self: HeapTable) !void {
    try self.create();
}

/// Adds a new page to the heap table.
pub fn addPage(self: HeapTable) !storage.Cache.PinnedPage {
    // Obtain the header page
    const page = try self.cache.getWriteable(.{
        .file = self.table_id.fullFileId(),
        .page = 0,
    });
    defer self.cache.unpin(page);

    // Increase the number of pages
    const header = FileHeader.fromPage(page.page);
    header.pages += 1;

    const page_id: Page.Id = @intCast(header.pages - 1);

    // Write the new page (zero-initialized)
    const new_page = try self.cache.getWriteable(.{
        .file = self.table_id.fullFileId(),
        .page = page_id,
    });
    @memset(&new_page.page.d, 0);

    return new_page;
}

/// Read the header of the HeapTable.
pub fn readHeader(self: HeapTable) !FileHeader {
    const page = try self.cache.get(.{
        .file = self.table_id.fullFileId(),
        .page = 0,
    });
    defer self.cache.unpin(page);

    return FileHeader.fromPage(page.page).*;
}

/// Get next value of the SERIAL counter
pub fn getNextSerial(self: HeapTable) !u64 {
    const page = try self.cache.getWriteable(.{
        .file = self.table_id.fullFileId(),
        .page = 0,
    });
    defer self.cache.unpin(page);

    const header = FileHeader.fromPage(page.page);
    return header.serial_counter.fetchAdd(1, .acq_rel);
}

/// Add a new tuple to the HeapTable.
pub fn addOneTuple(self: HeapTable, tuple: MemTuple, alloc: std.mem.Allocator) !MemTuple.Pos {
    const header = try self.readHeader();

    std.debug.assert(tuple.descr.has_extended);
    const ext = tuple.ext.?;
    const heap_tuple = HeapTuple.compact(
        .{
            .header = .{
                .xmin = ext.xmin,
                .xmax = ext.xmax,
            },
            .values = tuple.values,
        },
        tuple.descr,
        alloc,
    );

    // Go through pages to find a page that can fit this new tuple.
    // Create a new page if no pages have enough free space.
    var raw_page: storage.Cache.PinnedPage = page_id: for (1..header.pages) |page_id| {
        // Read the page
        const raw_page = try self.cache.get(.{
            .file = self.table_id.fullFileId(),
            .page = @intCast(page_id),
        });
        errdefer comptime unreachable;

        // Check if the tuple would fit
        const page = HeapPage.parse(raw_page.page, @intCast(page_id));
        if (page.fits(heap_tuple.data.len))
            break :page_id raw_page
        else
            self.cache.unpin(raw_page);
    } else try self.addPage();
    defer self.cache.unpin(raw_page);
    try self.cache.upgrade(&raw_page);

    // Write the tuple to the page
    const pos = block: {
        var page = HeapPage.parse(raw_page.page, raw_page.id.page);

        const index = page.add(heap_tuple.data);
        break :block MemTuple.Pos{
            .page_id = raw_page.id.page,
            .index = index,
        };
    };

    return pos;
}

/// Update the tuple directly on the page.
/// Care must be taken to ensure that the new data isn't bigger in size
/// than old data.
pub fn updateInPlace(self: HeapTable, tuple: MemTuple) !void {
    const pos = tuple.extended().pos;

    const raw_page = try self.cache.getWriteable(.{
        .file = self.table_id.fullFileId(),
        .page = pos.page_id,
    });
    defer self.cache.unpin(raw_page);
    var page = HeapPage.parse(raw_page.page, pos.page_id);

    // Check that we can actually update the tuple
    if (!page.canUpdateInPlace(pos.index, tuple))
        @panic("Cannot actually update in place!");
    page.updateInPlace(pos.index, tuple);
}

/// Delete the tuple directly on the page.
/// This sets xmax of the tuple to tid.
pub fn deleteTupleAt(self: HeapTable, pos: MemTuple.Pos, tid: ids.RealTransactionId) !void {
    const raw_page = try self.cache.getWriteable(.{
        .file = self.table_id.fullFileId(),
        .page = pos.page_id,
    });
    defer self.cache.unpin(raw_page);
    var page = HeapPage.parse(raw_page.page, pos.page_id);

    const tuple = HeapTuple{ .data = page.get(pos.index) };

    var header = tuple.getHeader();
    header.xmax = tid;
    tuple.setHeader(header);
}
