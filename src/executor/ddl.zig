//! Executors for various DDL statements

const Context = @import("Context.zig");
const Plan = @import("../planner.zig").Plan;
const catalog = @import("../catalog.zig");
const ids = @import("../ids.zig");
const heap = @import("../heap.zig");

/// Execute CREATE TABLE statement
pub fn executeCreateTable(stmt: Plan.Statement.CreateTable, cxt: *Context) !void {
    // Find zdb_seq_table_id sequence in the catalog
    var seq_scanner = cxt.catalog_cache.catalog.zdb_seqs.scan(
        &.{.seq_id},
        &.{@intFromEnum(catalog.SequenceId.zdb_seq_table_id)},
    );
    // Get its row
    var seq_row = seq_scanner.next();
    if (seq_row == null) {
        try cxt.output.print("ERROR: catalog is corrupted", .{});
        return Context.Error.MalformedData;
    }
    // Fetch the next table id from the sequence
    const table_id: ids.TableId = seq_row.?.seq_val;

    // Increment the sequence and update the catalog
    seq_row.?.seq_val += 1;
    try seq_scanner.updateLast(cxt.storage_cache, seq_row.?);

    // Add a row to zdb_rels catalog table
    try cxt.catalog_cache.catalog.zdb_rels.add(cxt.storage_cache, .{
        .rel_id = table_id,
        .rel_name = stmt.name,
    });

    // Go through all attributes
    const slice = stmt.descr.attrs.slice();
    for (slice.items(.name), slice.items(.t), 0..) |name, t, i| {
        // Add a row for each to zdb_attrs catalog table
        try cxt.catalog_cache.catalog.zdb_attrs.add(cxt.storage_cache, .{
            .attr_id = @intCast(i),
            .attr_rel_id = table_id,
            .attr_name = name,
            .attr_type = @intFromEnum(t),
        });
    }

    // Update all descriptors in the catalog
    try cxt.catalog_cache.updateDescriptors();

    // Create the actual heap table
    try heap.Table.init(
        cxt.storage_cache,
        .{ .db = cxt.db_id, .table = table_id },
    ).create();
}
