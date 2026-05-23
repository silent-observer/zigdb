//! Walker for a B+ Tree Index, performing various operations with it.
//! The walker has a position, usually pointing at some tuple in the leaf page.

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

gpa: std.mem.Allocator, // Allocator for new stuff
key_descr: *const TupleDescriptor, // Descriptor for keys in the index
index_id: ids.FullFileId, // Id of the index
root_page_id: ids.PageId, // Id of the root page
page_id: ids.PageId, // Current page id
tuple_index: usize, // Current tuple index on the page
page_count: u32, // Total number of pages
page: ?storage.Cache.PinnedPage, // Current page the scanner is reading
parsed_page: ?BTreeIndex.IndexPage, // Current page in its parsed state
cache: *storage.Cache, // Cache for disk access

/// Limit of tuples allowed in each node. Can be decreased for testing
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

/// Find the key in the index. The walker stops at the first key that's
/// greater or equal to the passed "key". If the key is present in the index,
/// the walker stops at the first key equal to it and returns true, otherwise
/// it stops at the place where the key should be inserted to, and returns false.
pub fn search(self: *BTreeWalker, key: []const Value) IndexError!bool {
    // We are starting from scratch, probably won't need the page we had
    if (self.page != null)
        self.closePage();
    // Start from the root page
    var page_id = self.root_page_id;
    var page = try self.cache.get(.{
        .file = self.index_id,
        .page = page_id,
    });
    errdefer self.cache.unpin(page);

    // We need an arena for temporary allocations
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();

    var parsed_page =
        BTreeIndex.IndexPage.parse(page.page, page_id);
    // Traverse the internal layers until we reach a leaf
    while (parsed_page.header.extra.layer > 0) {
        // Candidate for the branch to go down to. We start by assuming
        // it's the special 0th pointer to the smallest page, and increase it
        // when we know the key is greater than some tuple.
        // We are trying to find the smallest tuple in the node that's
        // greater or equal to
        var next_child = parsed_page.header.extra.u.internal.smallest_child;
        for (0..parsed_page.count()) |i| {
            // Get a tuple from the node
            const page_key: BTreeIndex.InternalTuple =
                .{ .data = parsed_page.get(i) };
            const page_key_data = try page_key.uncompact(
                self.key_descr,
                arena.allocator(),
            );

            // Compare it to the target key
            const o = Value.orderMany(
                page_key_data.values,
                key,
                self.key_descr,
            );
            switch (o) {
                .lt => {
                    // The tuple is still less than target key,
                    // we must look further.
                    // However, this could still be the correct branch,
                    // so remember this as a possible candidate.
                    next_child = page_key_data.header.child;
                },
                .eq => {
                    // We found the correct branch! Go down this branch immediately
                    next_child = page_key_data.header.child;
                    break;
                },
                .gt => {
                    // We overshot, the tuple is greater than the target key.
                    // The target key is probably in the previous branch we looked at,
                    // so just end the search here without updating the candidate.
                    break;
                },
            }
        }

        // We chose a branch to go down to, so advance to that one
        page_id = next_child;
        const new_page = try self.cache.get(.{
            .file = self.index_id,
            .page = page_id,
        });
        self.cache.unpin(page);
        page = new_page;
        parsed_page = BTreeIndex.IndexPage.parse(page.page, page_id);
    }

    // We are done traversing the internal nodes, and now we've reached
    // the leaf node we were looking for. It either contains the target key
    // or it doesnt.
    {
        // Update the page in the walker itself
        self.page_id = page_id;
        self.page = page;
        self.parsed_page = parsed_page;
        // Go through the tuples in the leaf page
        for (0..parsed_page.count()) |i| {
            const page_key: BTreeIndex.LeafTuple =
                .{ .data = parsed_page.get(i) };
            const page_key_data = try page_key.uncompact(
                self.key_descr,
                arena.allocator(),
            );

            // Compare it with the target key
            const o = Value.orderMany(
                page_key_data.values,
                key,
                self.key_descr,
            );
            self.tuple_index = i; // Update the walker position
            switch (o) {
                .eq => return true, // We found it!
                .gt => return false, // We passed it, this is the first one that's greater
                .lt => {}, // We are still not there yet
            }
        }
        // We have reached the end of the page but haven't found anything
        //
        self.tuple_index = self.parsed_page.?.count();
        return false;
    }
}

/// Get the tuple the walker is currently positioned at.
/// Return null if we are at the very end.
pub fn curr(self: *BTreeWalker) storage.Error!?BTreeIndex.LeafTuple {
    std.debug.assert(self.parsed_page.?.header.extra.layer == 0);
    if (self.tuple_index < self.parsed_page.?.count()) // Normal tuple from the page
        return .{ .data = self.parsed_page.?.get(self.tuple_index) }
    else { // The first tuple *after* this page, if there is any
        const next_page_id = self.parsed_page.?.header.extra.u.leaf.right;
        if (next_page_id == 0) // It was the last page, nothing after this
            return null;

        const next_page = try self.cache.get(.{
            .file = self.index_id,
            .page = next_page_id,
        });
        const parsed = BTreeIndex.IndexPage.parse(next_page.page, next_page_id);
        return .{ .data = parsed.get(0) };
    }
}

/// Advance the walker one tuple forward
pub fn advanceForward(self: *BTreeWalker) storage.Error!bool {
    try self.loadPage();
    std.debug.assert(self.parsed_page.?.header.extra.layer == 0);
    // Normal case, we are inside the node and can just advance the tuple index
    if (self.tuple_index < self.parsed_page.?.count() - 1) {
        self.tuple_index += 1;
        return true;
    }

    // We were at the last tuple of the page, we have to advance to the next one
    const next = self.parsed_page.?.header.extra.u.leaf.right;
    if (next == 0)
        return false;

    // Special case: we were pointing at the tuple past the end
    // of the page, so at the first tuple in the next one.
    // Now we have to advance to the second tuple of the next page
    if (self.tuple_index == self.parsed_page.?.count())
        self.tuple_index = 1
    else
        self.tuple_index = 0;

    self.closePage();
    self.page_id = next;
    try self.loadPage();
    return true;
}

/// Advance the walker one tuple backward
pub fn advanceBackward(self: *BTreeWalker) storage.Error!bool {
    try self.loadPage();
    std.debug.assert(self.parsed_page.?.header.extra.layer == 0);
    // Normal case, we are inside the node and can just advance the tuple index
    if (self.tuple_index > 0) {
        self.tuple_index -= 1;
        return true;
    }

    // We were at the first tuple of the page, we have to advance to the previous one
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

/// Insert the key-value entry into the index at the correct location
pub fn insert(self: *BTreeWalker, key: []const Value, val: MemTuple.Pos) IndexError!void {
    // Find the correct location for the new key
    _ = try self.search(key);
    // Arena for temporary allocations
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();

    // Make the tuple to insert
    const new_tuple = BTreeIndex.LeafTuple.compact(
        .{
            .header = .{ .pos = val },
            .values = @constCast(key),
        },
        self.key_descr,
        arena.allocator(),
    );
    // Proceed with the actual insertion
    try self.insertRawData(
        self.page_id,
        self.tuple_index,
        new_tuple.data,
    );
}

/// Insert a tuple (as raw bytes) at the given location
fn insertRawData(
    self: *BTreeWalker,
    page_id: ids.PageId,
    insert_index: usize,
    data: []const u8,
) IndexError!void {
    // Get the relevant page
    var page = try self.cache.get(.{
        .file = self.index_id,
        .page = page_id,
    });
    defer self.cache.unpin(page);
    var node =
        BTreeIndex.IndexPage.parse(page.page, page_id);

    // Check if we don't have capacity for new tuple
    if (!node.fits(data.len) or
        node.count() >= self.max_keys_per_node)
    {
        // Unfortunately we don't, we have to split the current node
        const old_count = node.count();

        const split_page_id = try self.splitNode(node);
        // The new page we got after splitting (the right half)
        const split_page = try self.cache.getWriteable(.{
            .file = self.index_id,
            .page = split_page_id,
        });
        defer self.cache.unpin(split_page);
        var split_node = BTreeIndex.IndexPage.parse(split_page.page, split_page_id);

        // How many tuples there are in the left half
        const right_count = split_node.count();
        // And the left half contains the rest
        const left_count = old_count - right_count;
        // Check if the new tuple should be placed in the right half
        if (insert_index > left_count) {
            split_node.insert(data, insert_index - left_count);
            return;
        }
    }

    // Get a writeable pin on the page
    try self.cache.upgrade(&page);
    // Insert the actual tuple
    node.insert(data, insert_index);
}

/// Split the node in half. The original node ends up being a left half of tuples,
/// while the new node is created for the right half. Id of the new page is returned.
/// Splitting updates the parents recursively as well.
fn splitNode(
    self: *BTreeWalker,
    node: BTreeIndex.IndexPage,
) IndexError!ids.PageId {
    const node_header = node.header;
    // Leaf and internal nodes have to be handled differently
    const is_leaf = node_header.extra.layer == 0;
    // Find the index of the split (how many tuples are left on the left page)
    const split_index = std.math.divCeil(
        usize,
        node.count(),
        2,
    ) catch unreachable;
    const index = BTreeIndex.init(
        self.cache,
        self.index_id.heap,
    );

    if (node.page_id == self.root_page_id) {
        // Special case for when we are trying to split the root.
        // Allocate a new higher-level root as a replacement.
        const new_root_page = try index.addPage();
        defer self.cache.unpin(new_root_page);

        var new_root = BTreeIndex.IndexPage.parse(
            new_root_page.page,
            new_root_page.id.page,
        );

        new_root.header.extra = .{
            .layer = node.header.extra.layer + 1,
            .u = .{
                .internal = .{
                    // The left node becomes the smallest child
                    .smallest_child = node.page_id,
                },
            },
            .parent = 0,
        };

        // Adjust the parent of our node
        node.header.extra.parent = new_root_page.id.page;

        // Update the root pointer
        self.root_page_id = new_root_page.id.page;
        // And the actual header page too
        {
            const header_page = try self.cache.getWriteable(.{
                .file = self.index_id,
                .page = 0,
            });
            defer self.cache.unpin(header_page);
            const h = BTreeIndex.FileHeader.fromPage(header_page.page);
            h.root = new_root_page.id.page;
        }
    }

    // Temporary arena allocator for our stuff
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    // Remember the split tuple's child node (if it has one)
    var split_tuple_child: ?ids.PageId = null;
    // Get the values from the tuple at the split
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
            // The sibling nodes' pointers should be adjusted too
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
            // We get it from the child pointer of the split tuple
            // (that will be removed in the split)
            right_node.header.extra.u.internal.smallest_child =
                split_tuple_child.?;
        }

        // Fix parents of the moved children
        if (!is_leaf) {
            // Fix the smallest child
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
            // Fix the normal children
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

    // Open the parent node
    const parent_id = node.header.extra.parent;
    const parent_page = try self.cache.get(.{
        .file = self.index_id,
        .page = parent_id,
    });
    defer self.cache.unpin(parent_page);

    const parent_node =
        BTreeIndex.IndexPage.parse(parent_page.page, parent_id);
    std.debug.assert(parent_node.header.extra.layer > 0);

    // Find where to insert in parent
    // We find it by looking for the pointer to the left node there,
    // and we should insert to the right of it
    const insert_index: usize = if (parent_node.header.extra.u.internal.smallest_child == old_page_id)
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
    descr.attrs.append(gpa, .{ .name = "i", .t = .b(.int4) }) catch oom();
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
        \\    Root: 8
        \\[1] Leaf (0):
        \\    P: 2, L: 0, R: 7
        \\    0: [7] -> (1, 3)
        \\    1: [59] -> (1, 13)
        \\[2] Node (1):
        \\    P: 8
        \\    -> 1
        \\    0: [89]
        \\    -> 7
        \\    1: [260]
        \\    -> 6
        \\    2: [425]
        \\    -> 4
        \\    3: [661]
        \\    -> 10
        \\[3] Leaf (0):
        \\    P: 9, L: 10, R: 5
        \\    0: [758] -> (1, 0)
        \\    1: [855] -> (1, 16)
        \\    2: [893] -> (1, 10)
        \\    3: [914] -> (1, 8)
        \\[4] Leaf (0):
        \\    P: 2, L: 6, R: 10
        \\    0: [425] -> (1, 1)
        \\    1: [524] -> (1, 14)
        \\    2: [582] -> (1, 19)
        \\[5] Leaf (0):
        \\    P: 9, L: 3, R: 0
        \\    0: [916] -> (1, 7)
        \\    1: [954] -> (1, 2)
        \\[6] Leaf (0):
        \\    P: 2, L: 7, R: 4
        \\    0: [260] -> (1, 6)
        \\    1: [284] -> (1, 11)
        \\    2: [359] -> (1, 5)
        \\[7] Leaf (0):
        \\    P: 2, L: 1, R: 6
        \\    0: [89] -> (1, 9)
        \\    1: [148] -> (1, 12)
        \\    2: [217] -> (1, 15)
        \\    3: [235] -> (1, 18)
        \\[8] Node (2):
        \\    P: 0
        \\    -> 2
        \\    0: [758]
        \\    -> 9
        \\[9] Node (1):
        \\    P: 8
        \\    -> 3
        \\    0: [916]
        \\    -> 5
        \\[10] Leaf (0):
        \\    P: 2, L: 4, R: 3
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
    descr.attrs.append(gpa, .{ .name = "i", .t = .b(.int4) }) catch oom();
    descr.attrs.append(gpa, .{ .name = "j", .t = .b(.int4) }) catch oom();
    descr.attrs.append(gpa, .{ .name = "t", .t = .b(.text) }) catch oom();
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
        \\    Root: 9
        \\[1] Leaf (0):
        \\    P: 2, L: 0, R: 16
        \\    0: [1, 6, "str2"] -> (1, 24)
        \\    1: [1, 8, "str10"] -> (1, 37)
        \\    2: [1, 8, "str4"] -> (1, 1)
        \\[2] Node (1):
        \\    P: 9
        \\    -> 1
        \\    0: [1, 9, "str3"]
        \\    -> 16
        \\    1: [2, 1, "str6"]
        \\    -> 11
        \\    2: [3, 6, "str1"]
        \\    -> 8
        \\    3: [3, 10, "str10"]
        \\    -> 3
        \\    4: [5, 6, "str1"]
        \\    -> 12
        \\[3] Leaf (0):
        \\    P: 2, L: 8, R: 12
        \\    0: [3, 10, "str10"] -> (1, 2)
        \\    1: [4, 7, "str1"] -> (1, 31)
        \\    2: [4, 10, "str3"] -> (1, 10)
        \\[4] Leaf (0):
        \\    P: 10, L: 7, R: 14
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
        \\    P: 10, L: 14, R: 15
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
        \\    P: 2, L: 11, R: 3
        \\    0: [3, 6, "str1"] -> (1, 6)
        \\    1: [3, 9, "str7"] -> (1, 5)
        \\[9] Node (2):
        \\    P: 0
        \\    -> 2
        \\    0: [6, 5, "str7"]
        \\    -> 13
        \\    1: [8, 5, "str10"]
        \\    -> 10
        \\[10] Node (1):
        \\    P: 9
        \\    -> 4
        \\    0: [9, 10, "str3"]
        \\    -> 14
        \\    1: [10, 2, "str10"]
        \\    -> 6
        \\    2: [10, 5, "str9"]
        \\    -> 15
        \\[11] Leaf (0):
        \\    P: 2, L: 16, R: 8
        \\    0: [2, 1, "str6"] -> (1, 4)
        \\    1: [2, 9, "str6"] -> (1, 23)
        \\    2: [3, 2, "str2"] -> (1, 25)
        \\    3: [3, 4, "str8"] -> (1, 27)
        \\[12] Leaf (0):
        \\    P: 2, L: 3, R: 5
        \\    0: [5, 6, "str1"] -> (1, 11)
        \\    1: [5, 7, "str9"] -> (1, 32)
        \\    2: [5, 10, "str8"] -> (1, 19)
        \\[13] Node (1):
        \\    P: 9
        \\    -> 5
        \\    0: [7, 6, "str2"]
        \\    -> 7
        \\[14] Leaf (0):
        \\    P: 10, L: 4, R: 6
        \\    0: [9, 10, "str3"] -> (1, 15)
        \\    1: [9, 10, "str4"] -> (1, 28)
        \\[15] Leaf (0):
        \\    P: 10, L: 6, R: 0
        \\    0: [10, 5, "str9"] -> (1, 29)
        \\    1: [10, 9, "str8"] -> (1, 22)
        \\[16] Leaf (0):
        \\    P: 2, L: 1, R: 11
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
        const c = try walker.curr();
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
        const c = try walker.curr();
        try std.testing.expect(c != null);
        try std.testing.expectEqual(x, c.?.getHeader().pos.index);

        try std.testing.expectEqual(x != 24, try walker.advanceBackward());
    }
}
