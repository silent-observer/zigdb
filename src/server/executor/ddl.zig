//! Executors for various DDL statements

const Context = @import("Context.zig");
const Plan = @import("../planner.zig").Plan;
const catalog = @import("../catalog.zig");
const ids = @import("common").ids;
const heap = @import("../heap.zig");

/// Execute CREATE TABLE statement
pub fn executeCreateTable(stmt: Plan.Statement.CreateTable, cxt: *Context) !void {
    // We need a real transaction to write data
    try cxt.s.shared.transaction_log.startRealTransaction(&cxt.s.current_tid);
    // Get a write lock on the catalog tables
    try cxt.s.shared.lock_manager.lock(
        .{ .table = .{
            .db = cxt.s.db_id,
            .table = @intFromEnum(catalog.tables.TableId.zdb_rels),
        } },
        .write,
        cxt.s.thread_id,
    );
    try cxt.s.shared.lock_manager.lock(
        .{ .table = .{
            .db = cxt.s.db_id,
            .table = @intFromEnum(catalog.tables.TableId.zdb_attrs),
        } },
        .write,
        cxt.s.thread_id,
    );
    // Fetch the next table id from the sequence
    const table_id: ids.TableId = try catalog.Sequence.init(
        .zdb_seq_table_id,
        cxt.s.catalog_cache,
        cxt.s.shared.storage_cache,
    ).next(cxt.s.current_tid.real);

    // Add a row to zdb_rels catalog table
    try cxt.s.catalog_cache.catalog.zdb_rels.add(
        cxt.s.shared.storage_cache,
        .{
            .rel_id = table_id,
            .rel_name = stmt.name,
        },
        cxt.s.current_tid.real,
    );

    // Go through all attributes
    const slice = stmt.descr.attrs.slice();
    for (slice.items(.name), slice.items(.t), 0..) |name, t, i| {
        // Add a row for each to zdb_attrs catalog table
        try cxt.s.catalog_cache.catalog.zdb_attrs.add(
            cxt.s.shared.storage_cache,
            .{
                .attr_id = @intCast(i),
                .attr_rel_id = table_id,
                .attr_name = name,
                .attr_type = @intFromEnum(t),
            },
            cxt.s.current_tid.real,
        );
    }

    // Update all descriptors in the catalog
    try cxt.s.catalog_cache.updateDescriptors();

    // Create the actual heap table
    try heap.Table.init(
        cxt.s.shared.storage_cache,
        .{ .db = cxt.s.db_id, .table = table_id },
    ).create();
}
