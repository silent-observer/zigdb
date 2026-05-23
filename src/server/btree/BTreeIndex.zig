//! Representation of a B+ tree index.
//! The index represents an ordered collection of "keys"
//! (each a small tuple by itself), with values being positions
//! of the actual tuples in the heap table. This allows you to quickly
//! look up the tuple in the heap table only knowing a small subset of
//! its attributes (the ones in the key).
//!
//! The index file itself consists of a single header page,
//! and then the data pages which are separated into "internal"
//! and "leaf" pages.
//!
//! The index is a B+ tree, with each data page representing 1 node.
//! The tree is uniform height: all branches have the exact same depth.
//! As such, we can assign exact "layer" to each node: the nodes without children
//! form layer 0, their parents form layer 1, grandparents form layer 2,
//! and this continues until the root node. All the nodes on layer 0 are
//! "leaf pages", and on all other layers are "internal pages".
//!
//! Internal pages are slotted pages with this logical structure:
//! - pointer 0 (X ≤ T1)
//! - tuple 1
//! - pointer 1 (T1 ≤ X ≤ T2)
//! - tuple 2
//! - pointer 2 (T2 ≤ X ≤ T3)
//!   ...
//! - tuple N
//! - pointer N (X ≥ TN)
//! When searching for a tuple, the subtree of pointer 0 contains all
//! values less than tuple 1. Pointer 1 contains values between tuple 1 and tuple 2,
//! and it is guaranteed that tuple 1 is the exact smallest tuple in the subtree.
//! Same applies to all pointers above 0th - the corresponding tuple is guaranteed to be
//! the smallest tuple present in that subtree.
//!
//! Leaf pages are simpler in this regard:
//! - tuple 1, position 1
//! - tuple 2, position 2
//!   ...
//! - tuple N, position N
//! They simply contain the tuples and "positions" of the corresponding tuples in the main
//! heap table. There is no extra pointer 0 in this case. However, leaf pages also form a
//! doubly-linked list together, so they contain pointers to left and right leaf page.
const std = @import("std");

const storage = @import("../storage.zig");
const Page = storage.Page;
const common = @import("common");
const MemTuple = common.MemTuple;
const ids = common.ids;

const BTreeIndex = @This();

cache: *storage.Cache,
index_id: ids.FullTableId,

/// Header for data pages (both leaf and internal ones).
pub const PageHeader = extern struct {
    layer: u8, // Layer, with 0 representing leaf nodes and >0 representing internal nodes
    _: [3]u8 = std.mem.zeroes([3]u8), // Padding
    parent: ids.PageId, // Id of the parent node, 0 if this is the root node
    u: Union, // Data that's different for internal and leaf pages

    pub const Union = extern union {
        // For internal nodes (layer > 0)
        internal: extern struct {
            // "Pointer 0", the id of the node contaning all tuples smaller than
            // even the first key in the internal node. Must be non-zero.
            smallest_child: ids.PageId,
            _: u32 = 0, // Padding
        },
        // For leaf nodes (layer = 0)
        leaf: extern struct {
            left: ids.PageId, // Pointer to the previous leaf in the linked list, 0 if none
            right: ids.PageId, // Pointer to the next leaf in the linked list, 0 if none
        },
    };
};
/// All pages are slotted pages with the header defined above
pub const IndexPage = storage.SlottedPage(PageHeader);

/// Header for all tuples in internal pages
pub const InternalTupleHeader = extern struct {
    child: ids.PageId, // Pointer to the child node (a page id)
};
/// Header for all tuples in leaf pages
pub const LeafTupleHeader = extern struct {
    pos: MemTuple.Pos, // Position of the main tuple in the heap page.
};
// Tuples stored in internal and leaf pages have different headers
pub const InternalTuple = common.CompactTuple(InternalTupleHeader);
pub const LeafTuple = common.CompactTuple(LeafTupleHeader);

/// Header of the whole B+ tree file, stored in 0th page
pub const FileHeader = extern struct {
    // 8-byte magic number to identify the file type
    magic_value: [8]u8 = Magic,
    // Id of the index
    index_id: ids.FullTableId,
    // Root page
    root: ids.PageId,
    // Total number of pages in the table (including the header page)
    pages: u32,

    const Magic: [8]u8 = .{ 'Z', 'D', 'B', '_', 'B', '3', 'I', 'X' };

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

/// Initializes a btree index handle.
/// Does not actually write anything to disk.
pub fn init(
    cache: *storage.Cache,
    index_id: ids.FullTableId,
) BTreeIndex {
    return .{
        .cache = cache,
        .index_id = index_id,
    };
}

/// Create a file for a new index.
/// Only initializes its 0th page.
pub fn create(self: BTreeIndex) storage.Error!void {
    const page = try self.cache.getWriteable(.{
        .file = self.index_id.fullFileId(),
        .page = 0,
    });
    defer self.cache.unpin(page);

    const header = FileHeader{
        .index_id = self.index_id,
        .root = 1,
        .pages = 2,
    };
    header.writePage(page.page);
}

/// Truncation is actually equivalent to creating a new index.
pub fn truncate(self: BTreeIndex) !void {
    try self.create();
}

/// Read the header of the btree index.
pub fn readHeader(self: BTreeIndex) storage.Error!FileHeader {
    const page = try self.cache.get(.{
        .file = self.index_id.fullFileId(),
        .page = 0,
    });
    defer self.cache.unpin(page);

    return FileHeader.fromPage(page.page).*;
}

/// Adds a new page to the btree index.
pub fn addPage(self: BTreeIndex) storage.Error!storage.Cache.PinnedPage {
    // Obtain the header page
    const page = try self.cache.getWriteable(.{
        .file = self.index_id.fullFileId(),
        .page = 0,
    });
    defer self.cache.unpin(page);

    // Increase the number of pages
    const header = FileHeader.fromPage(page.page);
    header.pages += 1;

    const page_id: Page.Id = @intCast(header.pages - 1);

    // Write the new page (zero-initialized)
    const new_page = try self.cache.getWriteable(.{
        .file = self.index_id.fullFileId(),
        .page = page_id,
    });
    @memset(&new_page.page.d, 0);

    return new_page;
}

/// Output the whole index in a formatted way (for debugging)
pub fn debugWrite(
    self: BTreeIndex,
    w: *std.Io.Writer,
    descr: *const common.TupleDescriptor,
    scratch: std.mem.Allocator,
) !void {
    var arena = std.heap.ArenaAllocator.init(scratch);
    defer arena.deinit();

    // The header page
    const header = try self.readHeader();
    try w.print("[0] Header:\n", .{});
    try w.print("    Index: {f}\n", .{header.index_id});
    try w.print("    Root: {}\n", .{header.root});
    for (1..header.pages) |page_id| {
        const page = try self.cache.get(.{
            .file = self.index_id.fullFileId(),
            .page = @intCast(page_id),
        });
        defer self.cache.unpin(page);

        // Get the node
        const node = IndexPage.parse(page.page, @intCast(page_id));
        if (node.header.extra.layer == 0) { // This is the leaf page
            try w.print("[{}] Leaf (0):\n", .{page_id});
            // Parent, left and right pointers
            try w.print(
                "    P: {}, L: {}, R: {}\n",
                .{
                    node.header.extra.parent,
                    node.header.extra.u.leaf.left,
                    node.header.extra.u.leaf.right,
                },
            );
            // Tuples in the page
            for (0..node.count()) |i| {
                try w.print("    {}: [", .{i});
                const tuple: LeafTuple = .{ .data = node.get(i) };
                const data = try tuple.uncompact(descr, arena.allocator());
                for (data.values, 0..) |v, j| {
                    if (j > 0)
                        try w.writeAll(", ");
                    try w.print("{f}", .{v});
                }
                try w.print(
                    "] -> ({}, {})\n",
                    .{
                        data.header.pos.page_id,
                        data.header.pos.index,
                    },
                );
            }
        } else { // This is the internal page
            try w.print(
                "[{}] Node ({}):\n",
                .{
                    page_id,
                    node.header.extra.layer,
                },
            );
            // Parent pointer
            try w.print("    P: {}\n", .{node.header.extra.parent});
            // 0th pointer
            try w.print("    -> {}\n", .{node.header.extra.u.internal.smallest_child});

            // Tuples in the node
            for (0..node.count()) |i| {
                try w.print("    {}: [", .{i});
                const tuple: InternalTuple = .{ .data = node.get(i) };
                const data = try tuple.uncompact(descr, arena.allocator());
                for (data.values, 0..) |v, j| {
                    if (j > 0)
                        try w.writeAll(", ");
                    try w.print("{f}", .{v});
                }
                try w.print("]\n    -> {}\n", .{data.header.child});
            }
        }
    }
}
