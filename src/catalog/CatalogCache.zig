//! This is an in-memory cache of the catalog in a specific database.
//! All access to the catalog must go through this cache.
//! The cache is initialized once at the start and then updated continuously.

const std = @import("std");

const common = @import("common");
const MemTuple = common.MemTuple;
const TupleDescriptor = common.TupleDescriptor;
const oom = common.oom;
const ids = common.ids;

const tables = @import("tables.zig");
const heap = @import("../heap.zig");
const storage = @import("../storage.zig");
const transaction = @import("../transaction.zig");

const CatalogCache = @This();

/// Allocator for all the system table data
gpa: std.mem.Allocator,
/// Storage cache for accessing tables
storage_cache: *storage.Cache,
/// Database id of the database this catalog belongs to
db_id: ids.DatabaseId,
/// The actual cache data
catalog: CatalogTables,
/// Cache of TupleDescriptors of all tables in the database
descr: std.array_hash_map.Auto(ids.TableId, TupleDescriptor),

/// All catalog tables
pub const CatalogTables = struct {
    zdb_rels: Table(tables.TableId.zdb_rels),
    zdb_attrs: Table(tables.TableId.zdb_attrs),
    zdb_seqs: Table(tables.TableId.zdb_seqs),
};

// Ideally, the CatalogTables type above should also be auto-generated, but
// this breaks code autocompletion, so for now it is defined manually.

// pub const CatalogTables = T: {
//     const ids = std.enums.values(tables.RelationId);

//     var field_names: [ids.len][]const u8 = undefined;
//     var field_types: [ids.len]type = undefined;
//     var field_attrs: [ids.len]std.builtin.Type.StructField.Attributes = undefined;
//     for (ids, 0..) |id, i| {
//         field_names[i] = @tagName(id);
//         field_types[i] = Table(id);
//         field_attrs[i] = .{};
//     }

//     const Result = @Struct(
//         .auto,
//         null,
//         &field_names,
//         &field_types,
//         &field_attrs,
//     );

//     break :T Result;
// };

/// Initialize the catalog cache. This does not read anything, the catalog is empty.
pub fn init(
    gpa: std.mem.Allocator,
    db_id: ids.DatabaseId,
    storage_cache: *storage.Cache,
) CatalogCache {
    var catalog: CatalogTables = undefined;
    inline for (std.enums.values(tables.TableId)) |id| {
        @field(catalog, @tagName(id)) = .init(gpa, db_id);
    }
    return CatalogCache{
        .db_id = db_id,
        .gpa = gpa,
        .storage_cache = storage_cache,
        .catalog = catalog,
        .descr = .empty,
    };
}

/// Free the memory corresponding to the catalog cache.
pub fn deinit(self: *CatalogCache) void {
    inline for (std.meta.fields(CatalogTables)) |field| {
        @field(self.catalog, field.name).deinit();
    }
    for (self.descr.values()) |*v| {
        v.attrs.deinit(self.gpa);
    }
    self.descr.deinit(self.gpa);
}

/// Update the catalog cache from the actual data on disk.
pub fn rebuild(self: *CatalogCache, snapshot: *const transaction.Snapshot) !void {
    // Go through all the fields in the CatalogTables struct
    inline for (std.meta.fields(CatalogTables)) |field| {
        // Rebuild each one
        try @field(self.catalog, field.name).rebuild(self.storage_cache, snapshot);
    }
    // Also update the descriptors
    try self.updateDescriptors();
}

/// Update the user table descriptors using the data in the cache.
/// Should be called every time catalog is modified.
pub fn updateDescriptors(self: *CatalogCache) !void {
    // Free all the old descriptors
    for (self.descr.values()) |*v| {
        v.attrs.deinit(self.gpa);
    }
    self.descr.clearRetainingCapacity();

    // Scan the zdb_rels table containing all the tables
    var rel_scanner: Table(tables.TableId.zdb_rels).Scanner =
        self.catalog.zdb_rels.scan(&.{}, &.{});

    while (rel_scanner.next()) |rel| {
        // Scan the zdb_attrs table to find the attributes in this table
        var attr_scanner: Table(tables.TableId.zdb_attrs).Scanner =
            self.catalog.zdb_attrs.scan(&.{.attr_rel_id}, &.{rel.rel_id});

        // Build the descriptor
        var descr: TupleDescriptor = .emptyExtended;
        while (attr_scanner.next()) |attr| {
            descr.attrs.append(self.gpa, .{
                .name = attr.attr_name,
                .t = @enumFromInt(attr.attr_type),
            }) catch oom();
        }
        // Put it in the cache
        self.descr.put(self.gpa, rel.rel_id, descr) catch oom();
    }
}

pub const Error = error{
    CatalogCorrupted,
};

/// Type representing a cache for the specific catalog table.
/// The type is generic so that the row of the table can be
/// a custom-built type for that specific catalog table.
pub fn Table(comptime id: tables.TableId) type {
    return struct {
        // Arena for the tuple data
        arena: std.heap.ArenaAllocator,
        // Database this table belongs to
        db_id: u32,
        // Descriptor of this catalog table
        descr: *const TupleDescriptor,
        // Actual tuples in the catalog table
        data: std.ArrayList(MemTuple),

        /// Type of this table
        const TSelf = @This();
        // Comptime-generated type for the row of this catalog table.
        /// It is a struct with fields directly corresponding to attributes.
        pub const Row = tables.Entry(id);

        /// Initialize an empty cache
        pub fn init(gpa: std.mem.Allocator, db_id: u32) TSelf {
            return .{
                .arena = .init(gpa),
                .db_id = db_id,
                .descr = tables.descriptor(id),
                .data = .empty,
            };
        }

        /// Free the tuples in the cache
        pub fn deinit(self: *TSelf) void {
            self.arena.deinit();
        }

        /// Rebuild the cache by reading from disk
        pub fn rebuild(self: *TSelf, cache: *storage.Cache, snapshot: *const transaction.Snapshot) !void {
            // Free all the existing tuples in the cache
            self.data.clearAndFree(self.arena.allocator());
            _ = self.arena.reset(.retain_capacity);

            // Scan the catalog table on disk
            var scanner = try heap.Scanner.init(
                cache,
                .{
                    .db = self.db_id,
                    .table = @intFromEnum(id),
                },
                self.descr,
                snapshot,
            );
            defer scanner.deinit();

            // Preallocate enough space in the cache
            self.data.ensureTotalCapacity(
                self.arena.allocator(),
                scanner.tuple_count,
            ) catch oom();

            // Add all tuples from the catalog table to the cache
            while (try scanner.next(self.arena.allocator())) |tuple| {
                self.data.append(self.arena.allocator(), tuple.tuple) catch oom();
            }
        }

        /// Check if two values of the attribute are equal
        fn attrEql(
            comptime attr: tables.SystemAttribute,
            a: tables.Attr(attr),
            b: tables.Attr(attr),
        ) bool {
            switch (tables.Attr(attr)) {
                i8, i16, i32, i64, bool => return a == b,
                []const u8 => return std.mem.eql(u8, a, b),
                else => comptime unreachable,
            }
        }

        /// Convert dynamic MemTuple to a static custom-built Row
        fn memTupleToRow(m: MemTuple) Row {
            var result: Row = undefined;
            // Go through all the fields in the Row struct
            inline for (std.meta.fields(Row), 0..) |f, i| {
                // Fill each one from the MemTuple
                @field(result, f.name) = m.get(f.type, i);
            }
            return result;
        }

        /// Convert static custom-built Row to a dynamic MemTuple
        fn rowToMemTuple(row: Row, alloc: std.mem.Allocator, new_tid: ids.TransactionId) MemTuple {
            var builder = MemTuple.Builder.init(
                alloc,
                tables.descriptor(id),
            );
            // Go through all the fields in the Row struct
            inline for (std.meta.fields(Row)) |f| {
                // Put each one into the MemTuple
                builder.push(f.type, @field(row, f.name));
            }
            builder.addExtended(.{
                .xmin = new_tid,
                .xmax = .invalid,
                .pos = .none,
            });
            return builder.finalize();
        }

        /// Scanner for a catalog table.
        /// Can also perform a filtered scan, checking that some attributes
        /// have given values. Only supports filtering by uint4 attributes (arbitrary amount)
        /// and text attribute (at most 1)
        pub const Scanner = struct {
            // Table this scanner corresponds to
            table: *TSelf,
            // Current index in the table
            index: usize,
            // Last returned Pos
            last_pos: MemTuple.Pos = .none,

            // Indexes of filtered uint4 attributes
            keys: []const u8,
            // Values for filtered uint4 attributes
            vals: []const u32,
            // Optional index of a filtered text attribute
            key_text: ?u8 = null,
            // Optional value for a filtered text attribute
            val_text: ?[]const u8 = null,
            // Should the text filtering ignore case?
            ignore_case: bool = false,

            /// Get the next Row from the catalog cache
            pub fn next(self: *Scanner) ?Row {
                // Go until we reach the end of the data
                outer: while (self.index < self.table.data.items.len) {
                    // Get the tuple
                    const tuple = self.table.data.items[self.index];
                    // Check uint4 filters
                    for (self.keys, self.vals) |k, v| {
                        const tuple_val = tuple.get(u32, k);
                        if (tuple_val != v) {
                            // If it doesn't match, we should check the next tuple
                            self.index += 1;
                            continue :outer;
                        }
                    }
                    // Check text filter
                    if (self.key_text) |key_text| {
                        const tuple_text = tuple.get([]const u8, key_text);
                        // Does the text match?
                        const match = if (self.ignore_case)
                            std.ascii.eqlIgnoreCase(tuple_text, self.val_text.?)
                        else
                            std.mem.eql(u8, tuple_text, self.val_text.?);

                        if (!match) {
                            // If it doesn't match, we should check the next tuple
                            self.index += 1;
                            continue :outer;
                        }
                    }
                    // Everything matched, return this tuple
                    self.index += 1;
                    self.last_pos = tuple.extended().pos;
                    return memTupleToRow(tuple);
                }
                // Reached the end of the table
                return null;
            }

            /// Update the last Row returned by the Scanner
            /// Note: you are not allowed to increase the size of the data in the row,
            /// since the update is performed in place.
            pub fn updateLast(self: *Scanner, cache: *storage.Cache, new: Row, tid: ids.TransactionId) !void {
                // Convert the new row to a tuple
                const tuple = rowToMemTuple(new, self.table.arena.allocator(), tid);
                tuple.extended().pos = self.last_pos;

                // Replace the tuple in the heap table
                try heap.Table.init(cache, .{
                    .db = self.table.db_id,
                    .table = @intFromEnum(id),
                }).updateInPlace(tuple);

                // Replace the tuple in the cache
                self.table.data.items[self.index].deinit(self.table.arena.allocator());
                self.table.data.items[self.index] = tuple;
            }
        };

        /// Perform a scan with uint4 filters.
        /// attrs is a list of uint4 attributes to check, vals are their desired values.
        ///
        /// So
        /// ```zig
        /// const scanner = zdb_rels.scan(&.{.rel_id}, &.{1000});
        /// ```
        /// is equivalent to SQL
        /// ```sql
        /// SELECT * FROM zdb_rels WHERE rel_id = 1000;
        /// ```
        pub fn scan(
            self: *TSelf,
            comptime attrs: []const tables.SystemAttribute,
            vals: []const u32,
        ) Scanner {
            std.debug.assert(vals.len == attrs.len);
            inline for (attrs) |a| {
                if (tables.Attr(a) != u32)
                    @compileError("Attribute " ++ @tagName(a) ++
                        " is " ++ @typeName(tables.Attr(a)) ++
                        ", not uint32, cannot use catalog scan");
            }

            const keys = comptime block: {
                var keys: [attrs.len]u8 = undefined;
                for (attrs, &keys) |a, *k|
                    k.* = tables.index(a);
                break :block keys;
            };

            return Scanner{
                .table = self,
                .index = 0,
                .keys = &keys,
                .vals = vals,
            };
        }

        /// Perform a scan with uint4 filters and 1 text filter.
        /// attr_text is the text attribute to check, val_text is its desired value.
        /// attrs is a list of uint4 attributes to check, vals are their desired values.
        ///
        /// So
        /// ```zig
        /// const scanner = zdb_attrs.scanText(.attr_name, "my_col", &.{.attr_rel_id}, &.{1000}, false);
        /// ```
        /// is equivalent to SQL
        /// ```sql
        /// SELECT * FROM zdb_attrs WHERE attr_name = 'my_col' AND attr_rel_id = 1000;
        /// ```
        pub fn scanText(
            self: *TSelf,
            comptime attr_text: tables.SystemAttribute,
            val_text: []const u8,
            comptime attrs: []const tables.SystemAttribute,
            vals: []const u32,
            ignore_case: bool,
        ) Scanner {
            std.debug.assert(vals.len == attrs.len);
            inline for (attrs) |a| {
                if (tables.Attr(a) != u32)
                    @compileError("Attribute " ++ @tagName(a) ++
                        " is " ++ @typeName(tables.Attr(a)) ++
                        ", not uint32, cannot use catalog scan");
            }
            if (tables.Attr(attr_text) != []const u8)
                @compileError("Attribute " ++ @tagName(attr_text) ++
                    " is " ++ @typeName(tables.Attr(attr_text)) ++
                    ", not text, cannot use catalog scan");

            const keys = comptime block: {
                var keys: [attrs.len]u8 = undefined;
                for (attrs, &keys) |a, *k|
                    k.* = tables.index(a);
                break :block keys;
            };

            return Scanner{
                .table = self,
                .index = 0,
                .keys = &keys,
                .vals = vals,
                .key_text = tables.index(attr_text),
                .val_text = val_text,
                .ignore_case = ignore_case,
            };
        }

        /// Perform a scan with uint4 filters and 1 text filter.
        /// attr_text is the text attribute to check, val_text is its desired value.
        /// attrs is a list of uint4 attributes to check, vals are their desired values.
        /// The case of the text attribute is significant.
        pub fn scanTextExact(
            self: *TSelf,
            comptime attr_text: tables.SystemAttribute,
            val_text: []const u8,
            comptime attrs: []const tables.SystemAttribute,
            vals: []const u32,
        ) Scanner {
            return self.scanText(attr_text, val_text, attrs, vals, false);
        }

        /// Perform a scan with uint4 filters and 1 text filter.
        /// attr_text is the text attribute to check, val_text is its desired value.
        /// attrs is a list of uint4 attributes to check, vals are their desired values.
        /// The case of the text attribute is ignored.
        pub fn scanTextIgnoreCase(
            self: *TSelf,
            comptime attr_text: tables.SystemAttribute,
            val_text: []const u8,
            comptime attrs: []const tables.SystemAttribute,
            vals: []const u32,
        ) Scanner {
            return self.scanText(attr_text, val_text, attrs, vals, true);
        }

        /// Adds a new row to the catalog table
        pub fn add(self: *TSelf, cache: *storage.Cache, row: Row, tid: ids.TransactionId) !void {
            const tuple = rowToMemTuple(row, self.arena.allocator(), tid);

            // Add the row to the heap table
            const pos = try heap.Table.init(
                cache,
                .{
                    .db = self.db_id,
                    .table = @intFromEnum(id),
                },
            ).addOneTuple(tuple);
            tuple.extended().pos = pos;

            // Add the row to the cache too
            self.data.append(self.arena.allocator(), tuple) catch oom();
        }
    };
}

pub const Sequence = struct {
    id: tables.SequenceId,
    cat: *CatalogCache,
    cache: *storage.Cache,

    pub fn init(id: tables.SequenceId, cat: *CatalogCache, cache: *storage.Cache) Sequence {
        return .{
            .id = id,
            .cat = cat,
            .cache = cache,
        };
    }

    pub fn next(self: Sequence, tid: ids.TransactionId) !u32 {
        // Find sequence in the catalog
        var seq_scanner = self.cat.catalog.zdb_seqs.scan(
            &.{.seq_id},
            &.{@intFromEnum(self.id)},
        );
        // Get its row
        var seq_row = seq_scanner.next() orelse return Error.CatalogCorrupted;
        // Fetch the next table id from the sequence
        const result = seq_row.seq_val;

        // Increment the sequence and update the catalog
        seq_row.seq_val += 1;
        try seq_scanner.updateLast(self.cache, seq_row, tid);

        return result;
    }
};

/// Create a new heap table without initializing the cache first.
fn createRaw(
    cache: *storage.Cache,
    db_id: ids.DatabaseId,
    comptime table_id: tables.TableId,
) !void {
    const id = ids.FullTableId{
        .db = db_id,
        .table = @intFromEnum(table_id),
    };
    try heap.Table.init(cache, id).create();
}

/// Create the catalog from scratch
pub fn build(self: *CatalogCache) !void {
    // Create the catalog tables
    try createRaw(self.storage_cache, self.db_id, .zdb_rels);
    try createRaw(self.storage_cache, self.db_id, .zdb_attrs);
    try createRaw(self.storage_cache, self.db_id, .zdb_seqs);

    // Go through all the tables and fill zdb_rels
    for (std.enums.values(tables.TableId)) |id| {
        try self.catalog.zdb_rels.add(self.storage_cache, .{
            .rel_id = @intFromEnum(id),
            .rel_name = @tagName(id),
        }, .frozen);
    }

    // Go through all the tables and their attributes and fill zdb_attrs
    for (std.enums.values(tables.TableId)) |rel_id| {
        const d = tables.descriptor(rel_id);
        const slice = d.attrs.slice();
        for (slice.items(.t), slice.items(.name), 0..) |dbtype, name, i| {
            try self.catalog.zdb_attrs.add(self.storage_cache, .{
                .attr_rel_id = @intFromEnum(rel_id),
                .attr_id = @intCast(i),
                .attr_type = @intFromEnum(dbtype),
                .attr_name = name,
            }, .frozen);
        }
    }

    // Create the default sequences and fill zdb_seqs
    try self.catalog.zdb_seqs.add(self.storage_cache, .{
        .seq_id = @intFromEnum(tables.SequenceId.zdb_seq_table_id),
        .seq_name = "zdb_seq_table_id",
        .seq_val = 1000,
    }, .frozen);
    try self.catalog.zdb_seqs.add(self.storage_cache, .{
        .seq_id = @intFromEnum(tables.SequenceId.zdb_seq_seq_id),
        .seq_name = "zdb_seq_seq_id",
        .seq_val = 1000,
    }, .frozen);

    try self.updateDescriptors();
}
