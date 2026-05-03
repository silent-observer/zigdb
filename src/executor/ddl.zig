//! Executors for various DDL statements

const Context = @import("Context.zig");
const Plan = @import("../planner.zig").Plan;
const catalog = @import("../catalog.zig");
const ids = @import("../ids.zig");
const heap = @import("../heap.zig");

/// Execute CREATE TABLE statement
pub fn executeCreateTable(stmt: Plan.Statement.CreateTable, cxt: *Context) !void {
    // Fetch the next table id from the sequence
    const table_id: ids.TableId = try catalog.Sequence.init(
        .zdb_seq_table_id,
        cxt.catalog_cache,
        cxt.storage_cache,
    ).next(cxt.tid);

    // Add a row to zdb_rels catalog table
    try cxt.catalog_cache.catalog.zdb_rels.add(cxt.storage_cache, .{
        .rel_id = table_id,
        .rel_name = stmt.name,
    }, cxt.tid);

    // Go through all attributes
    const slice = stmt.descr.attrs.slice();
    for (slice.items(.name), slice.items(.t), 0..) |name, t, i| {
        // Add a row for each to zdb_attrs catalog table
        try cxt.catalog_cache.catalog.zdb_attrs.add(cxt.storage_cache, .{
            .attr_id = @intCast(i),
            .attr_rel_id = table_id,
            .attr_name = name,
            .attr_type = @intFromEnum(t),
        }, cxt.tid);
    }

    // Update all descriptors in the catalog
    try cxt.catalog_cache.updateDescriptors();

    // Create the actual heap table
    try heap.Table.init(
        cxt.storage_cache,
        .{ .db = cxt.db_id, .table = table_id },
    ).create();
}
