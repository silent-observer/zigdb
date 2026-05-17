const std = @import("std");

const storage = @import("../storage.zig");
const Page = storage.Page;
const common = @import("common");
const MemTuple = common.MemTuple;
const ids = common.ids;

const BTreeIndex = @This();

cache: *storage.Cache,
index_id: ids.FullTableId,

pub const PageHeader = extern struct {
    layers_down: u8,
    _: [3]u8 = std.mem.zeroes([3]u8),
    parent: ids.PageId,
    u: Union,

    pub const Union = extern union {
        internal: extern struct {
            smallest_child: ids.PageId,
            _: u32 = 0,
        },
        leaf: extern struct {
            left: ids.PageId,
            right: ids.PageId,
        },
    };
};
pub const IndexPage = storage.SlottedPage(PageHeader);

pub const InternalTupleHeader = extern struct {
    child: ids.PageId,
};
pub const LeafTupleHeader = extern struct {
    pos: MemTuple.Pos,
};
pub const InternalTuple = common.CompactTuple(InternalTupleHeader);
pub const LeafTuple = common.CompactTuple(LeafTupleHeader);

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

/// Initializes a heap table handle.
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

/// Create a file for a new index table.
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

/// Read the header of the BTreeIndex.
pub fn readHeader(self: BTreeIndex) storage.Error!FileHeader {
    const page = try self.cache.get(.{
        .file = self.index_id.fullFileId(),
        .page = 0,
    });
    defer self.cache.unpin(page);

    return FileHeader.fromPage(page.page).*;
}

/// Adds a new page to the heap table.
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

        const node = IndexPage.parse(page.page, @intCast(page_id));
        if (node.header.extra.layers_down == 0) {
            try w.print("[{}] Leaf (0):\n", .{page_id});
            try w.print(
                "    P: {}, L: {}, R: {}\n",
                .{
                    node.header.extra.parent,
                    node.header.extra.u.leaf.left,
                    node.header.extra.u.leaf.right,
                },
            );
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
        } else {
            try w.print(
                "[{}] Node ({}):\n",
                .{
                    page_id,
                    node.header.extra.layers_down,
                },
            );
            try w.print("    P: {}\n", .{node.header.extra.parent});
            try w.print("    -> {}\n", .{node.header.extra.u.internal.smallest_child});

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
