//! Scanner of a heap table, performing the full table scan

const std = @import("std");

const RawDataFile = @import("../storage/RawDataFile.zig");
const Page = RawDataFile.Page;
const storage = @import("../storage.zig");
const transaction = @import("../transaction.zig");
const HeapTable = @import("HeapTable.zig");
const HeapPage = @import("HeapPage.zig");
const common = @import("common");
const MemTuple = common.MemTuple;
const TupleDescriptor = common.TupleDescriptor;
const oom = common.oom;
const ids = common.ids;

const HeapScanner = @This();

descr: *const TupleDescriptor,
table_id: ids.FullTableId,
page_id: ids.PageId, // Current page id
tuple_index: u16, // Current tuple index on the page
page_count: u32, // Total number of pages
page: ?storage.Cache.PinnedPage, // Current page the scanner is reading
parsed_page: ?HeapPage, // Current page in its parsed state
cache: *storage.Cache,
snapshot: *const transaction.Snapshot,

/// Create a new Scanner
pub fn init(
    cache: *storage.Cache,
    table_id: ids.FullTableId,
    descr: *const TupleDescriptor,
    snapshot: *const transaction.Snapshot,
) !HeapScanner {
    const header = try HeapTable.init(cache, table_id).readHeader();

    return .{
        .descr = descr,
        .table_id = table_id,
        .page_id = 1,
        .tuple_index = 0,
        .page_count = header.pages,
        .page = null,
        .parsed_page = null,
        .cache = cache,
        .snapshot = snapshot,
    };
}

/// Deinitialize the new Scanner, closing the pages
pub fn deinit(self: *HeapScanner) void {
    if (self.page) |p| self.cache.unpin(p);
}

/// Manually close the current page
fn closePage(self: *HeapScanner) void {
    self.cache.unpin(self.page.?);
    self.page = null;
    self.parsed_page = null;
}

/// Advance to the first non-empty page we can reach.
fn advanceToNonEmpty(self: *HeapScanner) !bool {
    // Continue until we reach the end of the table
    while (self.page_id < self.page_count) {
        // If the current page is not read and parsed, do it now
        if (self.page == null) {
            std.debug.assert(self.parsed_page == null);

            self.page = try self.cache.get(.{
                .file = self.table_id.fullFileId(),
                .page = self.page_id,
            });
            self.parsed_page = HeapPage.parse(self.page.?.page, self.page_id);
        }

        // If the page has tuple, we found what we were looking for
        if (self.parsed_page.?.offsets.len > 0) return true;

        // If not, advance to the next page
        self.page_id += 1;
        self.closePage();
    }
    // We reached the end of the table
    return false;
}

/// Advance to the next tuple.
fn advanceOne(self: *HeapScanner) !void {
    // This should only be done if we already have a valid page
    std.debug.assert(self.parsed_page != null);

    self.tuple_index += 1;
    // If we still have tuples on the current page, we're done
    if (self.tuple_index < self.parsed_page.?.offsets.len)
        return;

    // Advance to the next non-empty page if we have to
    self.tuple_index = 0;
    self.page_id += 1;
    self.closePage();
}

/// Check if the tuple is actually visible in this snapshot
fn tupleVisible(self: *HeapScanner, tuple: MemTuple) !bool {
    const ext = tuple.extended();
    const creation_visible = try self.snapshot.changesVisible(ext.xmin);
    const deletion_visible = try self.snapshot.changesVisible(ext.xmax);
    // The tuple is visible if we can see it was created, but we can't see it was deleted.
    return creation_visible and !deletion_visible;
}

/// Get the next tuple, allocating it with the given Allocator.
pub fn next(self: *HeapScanner, tuple_alloc: std.mem.Allocator) !?MemTuple {
    while (true) {
        // Ensure we have a valid non-empty page
        if (!try self.advanceToNonEmpty())
            return null;

        // Read the tuple from the page
        const result = self.parsed_page.?.read(
            self.tuple_index,
            self.descr,
            tuple_alloc,
        );

        // Advance to the next tuple
        try self.advanceOne();
        if (try self.tupleVisible(result))
            return result;
    }
}
