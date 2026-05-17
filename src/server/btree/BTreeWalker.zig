//! Walker for a B+ Tree Index, performing various operations with it

const std = @import("std");

const RawDataFile = @import("../storage/RawDataFile.zig");
const Page = RawDataFile.Page;
const storage = @import("../storage.zig");
const transaction = @import("../transaction.zig");
const BTreeIndex = @import("BTreeIndex.zig");
const common = @import("common");
const MemTuple = common.MemTuple;
const Value = common.Value;
const TupleDescriptor = common.TupleDescriptor;
const oom = common.oom;
const ids = common.ids;

const IndexError = storage.Error || error{MalformedTuple};

const BTreeWalker = @This();

gpa: std.mem.Allocator,
key_descr: *const TupleDescriptor,
index_id: ids.FullFileId,
root_page_id: ids.PageId,
page_id: ids.PageId, // Current page id
tuple_index: usize, // Current tuple index on the page
page_count: u32, // Total number of pages
page: ?storage.Cache.PinnedPage, // Current page the scanner is reading
parsed_page: ?BTreeIndex.IndexPage, // Current page in its parsed state
cache: *storage.Cache,

max_keys_per_node: usize = 128,

/// Create a new Walker
pub fn init(
    gpa: std.mem.Allocator,
    cache: *storage.Cache,
    index_id: ids.FullTableId,
    key_descr: *const TupleDescriptor,
) storage.Error!BTreeWalker {
    const header = try BTreeIndex.init(cache, index_id).readHeader();

    return .{
        .gpa = gpa,
        .key_descr = key_descr,
        .index_id = index_id.fullFileId(),
        .root_page_id = header.root,
        .page_id = header.root,
        .tuple_index = 0,
        .page_count = header.pages,
        .page = null,
        .parsed_page = null,
        .cache = cache,
    };
}

fn order(lhs: []const Value, rhs: []const Value, descr: *const TupleDescriptor) std.math.Order {
    for (lhs, rhs, descr.attrs.items) |l, r, att| {
        const o = l.order(r, att.t);
        if (o != .eq) return o;
    }
    return .eq;
}

pub fn search(self: *BTreeWalker, key: []const Value) IndexError!bool {
    self.closePage();
    var page_id = self.root_page_id;
    var page = try self.cache.get(.{
        .file = self.index_id,
        .page = page_id,
    });
    errdefer self.cache.unpin(page);

    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();

    var parsed_page =
        BTreeIndex.IndexPage.parse(page.page, page_id);
    while (parsed_page.header.extra.layers_down > 0) {
        var next_child = parsed_page.header.extra.u.internal.smallest_child;
        for (0..parsed_page.count()) |i| {
            const page_key: BTreeIndex.InternalTuple =
                .{ .data = parsed_page.get(i) };
            const page_key_data = try page_key.uncompact(
                self.key_descr,
                arena.allocator(),
            );

            const o = order(
                key,
                page_key_data.values,
                self.key_descr,
            );
            if (o == .gt or o == .eq)
                next_child = page_key_data.header.child;
            if (o == .eq or o == .lt)
                break;
        }

        page_id = next_child;
        const new_page = try self.cache.get(.{
            .file = self.index_id,
            .page = page_id,
        });
        self.cache.unpin(page);
        page = new_page;
        parsed_page = BTreeIndex.IndexPage.parse(page.page, page_id);
    }

    {
        self.page_id = page_id;
        self.page = page;
        self.parsed_page = parsed_page;
        for (0..parsed_page.count()) |i| {
            const page_key: BTreeIndex.LeafTuple =
                .{ .data = parsed_page.get(i) };
            const page_key_data = try page_key.uncompact(
                self.key_descr,
                arena.allocator(),
            );

            const o = order(
                key,
                page_key_data.values,
                self.key_descr,
            );
            self.tuple_index = i;
            switch (o) {
                .eq => return true,
                .lt => return false,
                .gt => {},
            }
        }
        self.tuple_index = self.parsed_page.?.count();
        return false;
    }
}

pub fn curr(self: *BTreeWalker) ?BTreeIndex.LeafTuple {
    std.debug.assert(self.parsed_page.?.header.extra.layers_down == 0);
    return if (self.tuple_index < self.parsed_page.?.count())
        .{ .data = self.parsed_page.?.get(self.tuple_index) }
    else
        null;
}

pub fn advanceForward(self: *BTreeWalker) storage.Error!bool {
    try self.loadPage();
    std.debug.assert(self.parsed_page.?.header.extra.layers_down == 0);
    if (self.tuple_index < self.parsed_page.?.count() - 1) {
        self.tuple_index += 1;
        return true;
    }

    const next = self.parsed_page.?.header.extra.u.leaf.right;
    if (next == 0)
        return false;

    self.closePage();
    self.page_id = next;
    try self.loadPage();
    self.tuple_index = 0;
    return true;
}

pub fn advanceBackward(self: *BTreeWalker) storage.Error!bool {
    try self.loadPage();
    std.debug.assert(self.parsed_page.?.header.extra.layers_down == 0);
    if (self.tuple_index > 0) {
        self.tuple_index -= 1;
        return true;
    }

    const next = self.parsed_page.?.header.extra.u.leaf.left;
    if (next == 0)
        return false;

    self.closePage();
    self.page_id = next;
    try self.loadPage();
    self.tuple_index = self.parsed_page.?.count() - 1;
    return true;
}

/// Deinitialize the new Scanner, closing the pages
pub fn deinit(self: BTreeWalker) void {
    if (self.page) |p| self.cache.unpin(p);
}

/// Manually close the current page
fn closePage(self: *BTreeWalker) void {
    if (self.page == null) return;
    self.cache.unpin(self.page.?);
    self.page = null;
    self.parsed_page = null;
}

/// Manually load the current page
fn loadPage(self: *BTreeWalker) storage.Error!void {
    if (self.page != null) return;
    self.page = try self.cache.get(.{
        .file = self.index_id,
        .page = self.page_id,
    });
    self.parsed_page = BTreeIndex.IndexPage.parse(self.page.?.page, self.page_id);
}

pub fn insert(self: *BTreeWalker, key: []const Value, val: MemTuple.Pos) IndexError!void {
    _ = try self.search(key);
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();

    const new_tuple = BTreeIndex.LeafTuple.compact(
        .{
            .header = .{ .pos = val },
            .values = @constCast(key),
        },
        self.key_descr,
        arena.allocator(),
    );
    try self.insertRawData(
        self.page_id,
        self.tuple_index,
        new_tuple.data,
    );
}

fn insertRawData(
    self: *BTreeWalker,
    page_id: ids.PageId,
    insert_index: usize,
    data: []const u8,
) IndexError!void {
    var page = try self.cache.get(.{
        .file = self.index_id,
        .page = page_id,
    });
    defer self.cache.unpin(page);
    var node =
        BTreeIndex.IndexPage.parse(page.page, page_id);

    if (!node.fits(data.len) or
        node.count() >= self.max_keys_per_node)
    {
        const old_count = node.count();

        const split_page_id = try self.splitNode(node);
        const split_page = try self.cache.getWriteable(.{
            .file = self.index_id,
            .page = split_page_id,
        });
        defer self.cache.unpin(split_page);
        var split_node = BTreeIndex.IndexPage.parse(split_page.page, split_page_id);

        const right_count = split_node.count();
        const left_count = old_count - right_count;
        if (insert_index > left_count) {
            split_node.insert(data, insert_index - left_count);
            return;
        }
    }

    try self.cache.upgrade(&page);
    node.insert(data, insert_index);
}

fn splitNode(
    self: *BTreeWalker,
    node: BTreeIndex.IndexPage,
) IndexError!ids.PageId {
    const node_header = node.header;
    const is_leaf = node_header.extra.layers_down == 0;
    const split_index = std.math.divCeil(
        usize,
        node.count(),
        2,
    ) catch unreachable;
    const index = BTreeIndex.init(
        self.cache,
        self.index_id.heap,
    );

    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    var split_tuple_child: ?ids.PageId = null;
    const split_tuple_values = if (is_leaf) values: {
        const tuple: BTreeIndex.LeafTuple = .{ .data = node.get(split_index) };
        const data = try tuple.uncompact(
            self.key_descr,
            arena.allocator(),
        );
        break :values data.values;
    } else values: {
        const tuple: BTreeIndex.InternalTuple = .{ .data = node.get(split_index) };
        const data = try tuple.uncompact(
            self.key_descr,
            arena.allocator(),
        );
        split_tuple_child = data.header.child;
        break :values data.values;
    };

    const old_page_id = node.page_id;
    const new_page_id = id: {
        // Create a new page for the right node
        const right_page = try index.addPage();
        defer self.cache.unpin(right_page);
        // Reuse the old page for the left node, but create new data for it
        const left_page = self.gpa.create(Page.Data) catch oom();
        @memset(&left_page.d, 0);
        defer self.gpa.destroy(left_page);

        // Parse two new nodes
        var right_node = BTreeIndex.IndexPage.parse(
            right_page.page,
            right_page.id.page,
        );
        var left_node = BTreeIndex.IndexPage.parse(
            left_page,
            node.page_id,
        );
        // Copy their extra headers from old node
        left_node.header.extra = node_header.extra;
        right_node.header.extra = node_header.extra;
        // Fill their data
        for (0..split_index) |i|
            _ = left_node.add(node.get(i));
        if (is_leaf)
            // Only leaf nodes preserve split tuple
            _ = right_node.add(node.get(split_index));
        for (split_index + 1..node.count()) |i|
            _ = right_node.add(node.get(i));

        // Adjust extra headers
        if (is_leaf) {
            // Leaf nodes need sibling pointers adjusted
            left_node.header.extra.u.leaf.right = right_node.page_id;
            right_node.header.extra.u.leaf.left = left_node.page_id;
            if (node_header.extra.u.leaf.left != 0) {
                const orig_left_page = try self.cache.getWriteable(.{
                    .file = self.index_id,
                    .page = node_header.extra.u.leaf.left,
                });
                defer self.cache.unpin(orig_left_page);
                var orig_left_node =
                    BTreeIndex.IndexPage.parse(orig_left_page.page, node_header.extra.u.leaf.left);
                orig_left_node.header.extra.u.leaf.right = left_node.page_id;
            }
            if (node_header.extra.u.leaf.right != 0) {
                const orig_right_page = try self.cache.getWriteable(.{
                    .file = self.index_id,
                    .page = node_header.extra.u.leaf.right,
                });
                defer self.cache.unpin(orig_right_page);
                var orig_right_node =
                    BTreeIndex.IndexPage.parse(orig_right_page.page, node_header.extra.u.leaf.left);
                orig_right_node.header.extra.u.leaf.left = right_node.page_id;
            }
        } else {
            // Internal nodes need smallest child pointer adjusted
            right_node.header.extra.u.internal.smallest_child =
                split_tuple_child.?;
        }

        // Fix parents of the moved children
        if (!is_leaf) {
            {
                const child_id = right_node.header.extra.u.internal.smallest_child;
                const child_page = try self.cache.getWriteable(.{
                    .file = self.index_id,
                    .page = child_id,
                });
                defer self.cache.unpin(child_page);
                var child_node =
                    BTreeIndex.IndexPage.parse(child_page.page, child_id);
                child_node.header.extra.parent = right_node.page_id;
            }
            for (0..right_node.count()) |i| {
                const tuple: BTreeIndex.InternalTuple = .{ .data = right_node.get(i) };
                const child_id = tuple.getHeader().child;
                const child_page = try self.cache.getWriteable(.{
                    .file = self.index_id,
                    .page = child_id,
                });
                defer self.cache.unpin(child_page);
                var child_node =
                    BTreeIndex.IndexPage.parse(child_page.page, child_id);
                child_node.header.extra.parent = right_node.page_id;
            }
        }

        // Copy new data into the original page
        node.page.d = left_page.d;
        break :id right_node.page_id;
    };

    // New tuple we will have to insert into parent
    const new_tuple = BTreeIndex.InternalTuple.compact(
        .{
            .header = .{ .child = new_page_id },
            .values = split_tuple_values,
        },
        self.key_descr,
        arena.allocator(),
    );

    // Did we just split the root?
    if (node.page_id == self.root_page_id) {
        // Special case for when the split page was actually root
        const new_root_page = try index.addPage();
        defer self.cache.unpin(new_root_page);

        var new_root = BTreeIndex.IndexPage.parse(
            new_root_page.page,
            new_root_page.id.page,
        );

        new_root.header.extra = .{
            .layers_down = node.header.extra.layers_down + 1,
            .u = .{
                .internal = .{
                    .smallest_child = old_page_id,
                },
            },
            .parent = 0,
        };

        new_root.insert(new_tuple.data, 0);
        self.root_page_id = new_root_page.id.page;
        node.header.extra.parent = new_root_page.id.page;
        {
            const right_page = try self.cache.getWriteable(.{
                .file = self.index_id,
                .page = new_page_id,
            });
            defer self.cache.unpin(right_page);
            var right_node =
                BTreeIndex.IndexPage.parse(right_page.page, new_page_id);
            right_node.header.extra.parent = new_root_page.id.page;
        }
        {
            const header_page = try self.cache.getWriteable(.{
                .file = self.index_id,
                .page = 0,
            });
            defer self.cache.unpin(header_page);
            const h = BTreeIndex.FileHeader.fromPage(header_page.page);
            h.root = new_root_page.id.page;
        }
    } else {
        // Normal proceedings, read parent node
        const parent_id = node.header.extra.parent;
        const parent_page = try self.cache.get(.{
            .file = self.index_id,
            .page = parent_id,
        });
        defer self.cache.unpin(parent_page);

        const parent_node =
            BTreeIndex.IndexPage.parse(parent_page.page, parent_id);
        std.debug.assert(parent_node.header.extra.layers_down > 0);

        // Find where to insert in parent
        const insert_index = if (parent_node.header.extra.u.internal.smallest_child == old_page_id)
            0
        else index: for (0..parent_node.count()) |i| {
            const page_key: BTreeIndex.InternalTuple =
                .{ .data = parent_node.get(i) };
            if (page_key.getHeader().child == old_page_id)
                break :index i + 1;
        } else @panic("Did not find the expected pointer in BTree Index!");

        // Recurse to parent, inserting the new tuple into it
        try self.insertRawData(
            parent_id,
            insert_index,
            new_tuple.data,
        );
    }

    return new_page_id;
}

test "basic btree index" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var cache = storage.Cache.initMock(gpa, io, "");
    defer cache.deinit();

    const index = BTreeIndex.init(
        &cache,
        .{ .db = 1, .table = 1001 },
    );
    try index.create();

    var descr = TupleDescriptor.empty;
    descr.attrs.append(gpa, .{ .name = "i", .t = .int4 }) catch oom();
    defer descr.attrs.deinit(gpa);

    var walker = try BTreeWalker.init(
        gpa,
        &cache,
        .{ .db = 1, .table = 1001 },
        &descr,
    );
    walker.max_keys_per_node = 4;
    defer walker.deinit();

    var rand = std.Random.DefaultPrng.init(1234);
    const r = rand.random();

    for (0..20) |i| {
        try walker.insert(
            &.{.{ .int = r.intRangeAtMost(i64, 1, 1000) }},
            .{ .page_id = 1, .index = @intCast(i) },
        );
    }

    var w = std.Io.Writer.Allocating.init(gpa);
    defer w.deinit();
    try index.debugWrite(&w.writer, &descr, gpa);

    try std.testing.expectEqualStrings(
        \\[0] Header:
        \\    Index: 1/1001
        \\    Root: 9
        \\[1] Leaf (0):
        \\    P: 3, L: 0, R: 7
        \\    0: [7] -> (1, 3)
        \\    1: [59] -> (1, 13)
        \\[2] Leaf (0):
        \\    P: 8, L: 10, R: 5
        \\    0: [758] -> (1, 0)
        \\    1: [855] -> (1, 16)
        \\    2: [893] -> (1, 10)
        \\    3: [914] -> (1, 8)
        \\[3] Node (1):
        \\    P: 9
        \\    -> 1
        \\    0: [89]
        \\    -> 7
        \\    1: [260]
        \\    -> 6
        \\    2: [425]
        \\    -> 4
        \\    3: [661]
        \\    -> 10
        \\[4] Leaf (0):
        \\    P: 3, L: 6, R: 10
        \\    0: [425] -> (1, 1)
        \\    1: [524] -> (1, 14)
        \\    2: [582] -> (1, 19)
        \\[5] Leaf (0):
        \\    P: 8, L: 2, R: 0
        \\    0: [916] -> (1, 7)
        \\    1: [954] -> (1, 2)
        \\[6] Leaf (0):
        \\    P: 3, L: 7, R: 4
        \\    0: [260] -> (1, 6)
        \\    1: [284] -> (1, 11)
        \\    2: [359] -> (1, 5)
        \\[7] Leaf (0):
        \\    P: 3, L: 1, R: 6
        \\    0: [89] -> (1, 9)
        \\    1: [148] -> (1, 12)
        \\    2: [217] -> (1, 15)
        \\    3: [235] -> (1, 18)
        \\[8] Node (1):
        \\    P: 9
        \\    -> 2
        \\    0: [916]
        \\    -> 5
        \\[9] Node (2):
        \\    P: 0
        \\    -> 3
        \\    0: [758]
        \\    -> 8
        \\[10] Leaf (0):
        \\    P: 3, L: 4, R: 2
        \\    0: [661] -> (1, 17)
        \\    1: [713] -> (1, 4)
        \\
    , w.written());
}

test "complex btree index" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var cache = storage.Cache.initMock(gpa, io, "");
    defer cache.deinit();

    const index = BTreeIndex.init(
        &cache,
        .{ .db = 1, .table = 1001 },
    );
    try index.create();

    var descr = TupleDescriptor.empty;
    descr.attrs.append(gpa, .{ .name = "i", .t = .int4 }) catch oom();
    descr.attrs.append(gpa, .{ .name = "j", .t = .int4 }) catch oom();
    descr.attrs.append(gpa, .{ .name = "t", .t = .text }) catch oom();
    defer descr.attrs.deinit(gpa);

    var walker = try BTreeWalker.init(
        gpa,
        &cache,
        .{ .db = 1, .table = 1001 },
        &descr,
    );
    walker.max_keys_per_node = 5;
    defer walker.deinit();

    var rand = std.Random.DefaultPrng.init(1234);
    const r = rand.random();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    for (0..40) |i| {
        try walker.insert(
            &.{
                .{ .int = r.intRangeAtMost(i64, 1, 10) },
                .{ .int = r.intRangeAtMost(i64, 1, 10) },
                .{ .text = .makeRaw(std.fmt.allocPrint(
                    arena.allocator(),
                    "str{}",
                    .{r.intRangeAtMost(i64, 1, 10)},
                ) catch oom()) },
            },
            .{ .page_id = 1, .index = @intCast(i) },
        );
    }

    var w = std.Io.Writer.Allocating.init(gpa);
    defer w.deinit();
    try index.debugWrite(&w.writer, &descr, gpa);

    try std.testing.expectEqualStrings(
        \\[0] Header:
        \\    Index: 1/1001
        \\    Root: 10
        \\[1] Leaf (0):
        \\    P: 3, L: 0, R: 16
        \\    0: [1, 6, "str2"] -> (1, 24)
        \\    1: [1, 8, "str10"] -> (1, 37)
        \\    2: [1, 8, "str4"] -> (1, 1)
        \\[2] Leaf (0):
        \\    P: 3, L: 8, R: 12
        \\    0: [3, 10, "str10"] -> (1, 2)
        \\    1: [4, 7, "str1"] -> (1, 31)
        \\    2: [4, 10, "str3"] -> (1, 10)
        \\[3] Node (1):
        \\    P: 10
        \\    -> 1
        \\    0: [1, 9, "str3"]
        \\    -> 16
        \\    1: [2, 1, "str6"]
        \\    -> 11
        \\    2: [3, 6, "str1"]
        \\    -> 8
        \\    3: [3, 10, "str10"]
        \\    -> 2
        \\    4: [5, 6, "str1"]
        \\    -> 12
        \\[4] Leaf (0):
        \\    P: 9, L: 7, R: 14
        \\    0: [8, 5, "str10"] -> (1, 0)
        \\    1: [8, 7, "str3"] -> (1, 21)
        \\    2: [8, 7, "str7"] -> (1, 33)
        \\    3: [9, 8, "str1"] -> (1, 7)
        \\[5] Leaf (0):
        \\    P: 13, L: 12, R: 7
        \\    0: [6, 5, "str7"] -> (1, 20)
        \\    1: [6, 5, "str7"] -> (1, 9)
        \\    2: [7, 4, "str2"] -> (1, 26)
        \\    3: [7, 4, "str2"] -> (1, 16)
        \\    4: [7, 4, "str7"] -> (1, 8)
        \\[6] Leaf (0):
        \\    P: 9, L: 14, R: 15
        \\    0: [10, 2, "str10"] -> (1, 12)
        \\    1: [10, 2, "str6"] -> (1, 18)
        \\    2: [10, 3, "str4"] -> (1, 35)
        \\    3: [10, 5, "str10"] -> (1, 14)
        \\[7] Leaf (0):
        \\    P: 13, L: 5, R: 4
        \\    0: [7, 6, "str2"] -> (1, 13)
        \\    1: [7, 6, "str8"] -> (1, 17)
        \\    2: [7, 10, "str4"] -> (1, 36)
        \\    3: [8, 1, "str7"] -> (1, 34)
        \\    4: [8, 3, "str4"] -> (1, 30)
        \\[8] Leaf (0):
        \\    P: 3, L: 11, R: 2
        \\    0: [3, 6, "str1"] -> (1, 6)
        \\    1: [3, 9, "str7"] -> (1, 5)
        \\[9] Node (1):
        \\    P: 10
        \\    -> 4
        \\    0: [9, 10, "str3"]
        \\    -> 14
        \\    1: [10, 2, "str10"]
        \\    -> 6
        \\    2: [10, 5, "str9"]
        \\    -> 15
        \\[10] Node (2):
        \\    P: 0
        \\    -> 3
        \\    0: [6, 5, "str7"]
        \\    -> 13
        \\    1: [8, 5, "str10"]
        \\    -> 9
        \\[11] Leaf (0):
        \\    P: 3, L: 16, R: 8
        \\    0: [2, 1, "str6"] -> (1, 4)
        \\    1: [2, 9, "str6"] -> (1, 23)
        \\    2: [3, 2, "str2"] -> (1, 25)
        \\    3: [3, 4, "str8"] -> (1, 27)
        \\[12] Leaf (0):
        \\    P: 3, L: 2, R: 5
        \\    0: [5, 6, "str1"] -> (1, 11)
        \\    1: [5, 7, "str9"] -> (1, 32)
        \\    2: [5, 10, "str8"] -> (1, 19)
        \\[13] Node (1):
        \\    P: 10
        \\    -> 5
        \\    0: [7, 6, "str2"]
        \\    -> 7
        \\[14] Leaf (0):
        \\    P: 9, L: 4, R: 6
        \\    0: [9, 10, "str3"] -> (1, 15)
        \\    1: [9, 10, "str4"] -> (1, 28)
        \\[15] Leaf (0):
        \\    P: 9, L: 6, R: 0
        \\    0: [10, 5, "str9"] -> (1, 29)
        \\    1: [10, 9, "str8"] -> (1, 22)
        \\[16] Leaf (0):
        \\    P: 3, L: 1, R: 11
        \\    0: [1, 9, "str3"] -> (1, 3)
        \\    1: [1, 9, "str4"] -> (1, 38)
        \\    2: [2, 1, "str5"] -> (1, 39)
        \\
    , w.written());

    try std.testing.expectEqual(try walker.search(&.{
        .{ .int = 5 },
        .{ .int = 7 },
        .{ .text = .makeRaw("str9") },
    }), true);

    for (&[_]u16{ 32, 19, 20, 9, 26, 16, 8, 13, 17 }) |x| {
        const c = walker.curr();
        try std.testing.expect(c != null);
        try std.testing.expectEqual(x, c.?.getHeader().pos.index);

        try std.testing.expectEqual(true, try walker.advanceForward());
    }

    try std.testing.expectEqual(try walker.search(&.{
        .{ .int = 2 },
        .{ .int = 1 },
        .{ .text = .makeRaw("str6") },
    }), true);

    for (&[_]u16{ 4, 39, 38, 3, 1, 37, 24 }) |x| {
        const c = walker.curr();
        try std.testing.expect(c != null);
        try std.testing.expectEqual(x, c.?.getHeader().pos.index);

        try std.testing.expectEqual(x != 24, try walker.advanceBackward());
    }
}
