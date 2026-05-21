//! Executors for various DDL statements

const std = @import("std");
const Context = @import("Context.zig");
const Plan = @import("../planner.zig").Plan;
const catalog = @import("../catalog.zig");
const common = @import("common");
const ids = common.ids;
const heap = @import("../heap.zig");
const btree = @import("../btree.zig");
const Session = @import("../Session.zig");
const toaster = @import("../toaster.zig");
const oom = common.oom;

/// Execute CREATE TABLE statement
pub fn executeCreateTable(stmt: Plan.Statement.CreateTable, cxt: *Context) ![]const u8 {
    const s = Session.get();
    // We need a real transaction to write data
    try s.shared.transaction_log.startRealTransaction(&s.current_tid);
    // Get a write lock on the catalog tables
    try s.shared.lock_manager.lock(
        .{ .table = .{
            .db = s.db_id,
            .table = @intFromEnum(catalog.tables.TableId.zdb_rels),
        } },
        .write,
        s.thread_id,
    );
    try s.shared.lock_manager.lock(
        .{ .table = .{
            .db = s.db_id,
            .table = @intFromEnum(catalog.tables.TableId.zdb_attrs),
        } },
        .write,
        s.thread_id,
    );
    // Generate the next table id
    const table_id: ids.TableId = try s.shared.variables_cache.nextObjectId();

    // Do we need a toast table?
    const toast_table_id: ?ids.TableId = if (toaster.hasToastable(stmt.descr))
        try s.shared.variables_cache.nextObjectId()
    else
        null;

    // Add a row to zdb_rels catalog table
    try s.catalog_cache.catalog.zdb_rels.add(
        s.shared.storage_cache,
        .{
            .rel_id = table_id,
            .rel_name = .makeRaw(stmt.name),
            .rel_toast_id = toast_table_id,
        },
        s.current_tid.real,
    );

    // Go through all attributes
    for (stmt.descr.attrs.items, 0..) |att, i| {
        // Add a row for each to zdb_attrs catalog table
        try s.catalog_cache.catalog.zdb_attrs.add(
            s.shared.storage_cache,
            .{
                .attr_id = @intCast(i),
                .attr_rel_id = table_id,
                .attr_name = .makeRaw(att.name),
                .attr_type = att.t,
            },
            s.current_tid.real,
        );
    }

    // Create the toast table if needed
    if (toast_table_id) |toast_id| {
        const toast_table_name = std.fmt.allocPrint(
            cxt.alloc,
            "{s}_toast",
            .{stmt.name},
        ) catch oom();

        try s.catalog_cache.catalog.zdb_rels.add(
            s.shared.storage_cache,
            .{
                .rel_id = toast_id,
                .rel_name = .makeRaw(toast_table_name),
                .rel_toast_id = null,
            },
            s.current_tid.real,
        );
        try s.catalog_cache.catalog.zdb_attrs.add(
            s.shared.storage_cache,
            .{
                .attr_id = 0,
                .attr_rel_id = toast_id,
                .attr_name = .makeRaw("toast_id"),
                .attr_type = .b(.serial),
            },
            s.current_tid.real,
        );
        try s.catalog_cache.catalog.zdb_attrs.add(
            s.shared.storage_cache,
            .{
                .attr_id = 1,
                .attr_rel_id = toast_id,
                .attr_name = .makeRaw("toast_seq"),
                .attr_type = .b(.uint4),
            },
            s.current_tid.real,
        );
        try s.catalog_cache.catalog.zdb_attrs.add(
            s.shared.storage_cache,
            .{
                .attr_id = 2,
                .attr_rel_id = toast_id,
                .attr_name = .makeRaw("toast_data"),
                .attr_type = .b(.text),
            },
            s.current_tid.real,
        );

        // Create the actual heap table
        try heap.Table.init(
            s.shared.storage_cache,
            .{ .db = s.db_id, .table = toast_id },
        ).create();
    }

    // Update all descriptors in the catalog
    try s.catalog_cache.updateDescriptors();

    // Create the actual heap table
    try heap.Table.init(
        s.shared.storage_cache,
        .{ .db = s.db_id, .table = table_id },
    ).create();

    return "CREATE TABLE";
}

/// Execute DROP TABLE statement
pub fn executeDropTable(stmt: Plan.Statement.DropTable) ![]const u8 {
    const s = Session.get();
    // We need a real transaction to write data
    try s.shared.transaction_log.startRealTransaction(&s.current_tid);
    // Get an exclusive lock on the table itself
    try s.shared.lock_manager.lock(
        .{ .table = .{
            .db = s.db_id,
            .table = stmt.table,
        } },
        .exclusive,
        s.thread_id,
    );
    // Get a write lock on the catalog tables
    try s.shared.lock_manager.lock(
        .{ .table = .{
            .db = s.db_id,
            .table = @intFromEnum(catalog.tables.TableId.zdb_rels),
        } },
        .write,
        s.thread_id,
    );
    try s.shared.lock_manager.lock(
        .{ .table = .{
            .db = s.db_id,
            .table = @intFromEnum(catalog.tables.TableId.zdb_attrs),
        } },
        .write,
        s.thread_id,
    );

    // Scan through the zdb_rels catalog table
    {
        var scan = s.catalog_cache.catalog.zdb_rels.scan(
            &.{.rel_id},
            &.{stmt.table},
        );
        _ = scan.next().?;
        try scan.deleteLast(s.shared.storage_cache, s.current_tid.real);
        std.debug.assert(scan.next() == null);
    }

    // Scan through the zdb_attrs catalog table
    {
        var scan = s.catalog_cache.catalog.zdb_attrs.scan(
            &.{.attr_rel_id},
            &.{stmt.table},
        );
        while (scan.next()) |_| {
            try scan.deleteLast(s.shared.storage_cache, s.current_tid.real);
        }
    }

    // Delete the toast table too if it exists
    if (stmt.toast_table) |id| {
        // Scan through the zdb_rels catalog table
        {
            var scan = s.catalog_cache.catalog.zdb_rels.scan(
                &.{.rel_id},
                &.{id},
            );
            _ = scan.next().?;
            try scan.deleteLast(s.shared.storage_cache, s.current_tid.real);
            std.debug.assert(scan.next() == null);
        }
        // Scan through the zdb_attrs catalog table
        {
            var scan = s.catalog_cache.catalog.zdb_attrs.scan(
                &.{.attr_rel_id},
                &.{id},
            );
            while (scan.next()) |_| {
                try scan.deleteLast(s.shared.storage_cache, s.current_tid.real);
            }
        }
    }

    // Update all descriptors in the catalog
    try s.catalog_cache.updateDescriptors();

    return "DROP TABLE";
}

/// Execute CREATE INDEX statement
pub fn executeCreateIndex(stmt: Plan.Statement.CreateIndex, cxt: *Context) ![]const u8 {
    const s = Session.get();
    // We need a real transaction to write data
    try s.shared.transaction_log.startRealTransaction(&s.current_tid);
    // Get a write lock on the catalog tables
    try s.shared.lock_manager.lock(
        .{ .table = .{
            .db = s.db_id,
            .table = @intFromEnum(catalog.tables.TableId.zdb_indexes),
        } },
        .write,
        s.thread_id,
    );
    // Generate the next table id
    const index_id: ids.TableId = try s.shared.variables_cache.nextObjectId();

    const cols: []common.Value = cxt.alloc.alloc(common.Value, stmt.cols.len) catch oom();
    for (stmt.cols, cols) |c, *v|
        v.* = .{ .int = c };

    // Add a row to zdb_rels catalog table
    try s.catalog_cache.catalog.zdb_indexes.add(
        s.shared.storage_cache,
        .{
            .index_id = index_id,
            .index_rel_id = stmt.table,
            .index_name = .makeRaw(stmt.name),
            .index_cols = cols,
        },
        s.current_tid.real,
    );

    // Update all descriptors in the catalog
    try s.catalog_cache.updateDescriptors();

    // Create the actual index
    try btree.Index.init(
        s.shared.storage_cache,
        .{ .db = s.db_id, .table = index_id },
    ).create();

    return "CREATE INDEX";
}

/// Execute DROP INDEX statement
pub fn executeDropIndex(stmt: Plan.Statement.DropIndex) ![]const u8 {
    const s = Session.get();
    // We need a real transaction to write data
    try s.shared.transaction_log.startRealTransaction(&s.current_tid);
    // Get an exclusive lock on the index itself
    try s.shared.lock_manager.lock(
        .{ .table = .{
            .db = s.db_id,
            .table = stmt.index,
        } },
        .exclusive,
        s.thread_id,
    );
    // Get a write lock on the catalog table
    try s.shared.lock_manager.lock(
        .{ .table = .{
            .db = s.db_id,
            .table = @intFromEnum(catalog.tables.TableId.zdb_indexes),
        } },
        .write,
        s.thread_id,
    );

    // Scan through the zdb_indexes catalog table
    {
        var scan = s.catalog_cache.catalog.zdb_indexes.scan(
            &.{.index_id},
            &.{stmt.index},
        );
        _ = scan.next().?;
        try scan.deleteLast(s.shared.storage_cache, s.current_tid.real);
        std.debug.assert(scan.next() == null);
    }

    // Update all descriptors in the catalog
    try s.catalog_cache.updateDescriptors();

    return "DROP INDEX";
}
