//! Executor for table-modifying statements

const Context = @import("Context.zig");
const Plan = @import("../planner.zig").Plan;
const catalog = @import("../catalog.zig");
const ids = @import("../ids.zig");
const heap = @import("../heap.zig");
const Executor = @import("Executor.zig");

/// Execute INSERT statement
pub fn executeInsert(stmt: Plan.Statement.Insert, cxt: *Context) !void {
    // Initialize the source data node
    try Executor.initDataNode(stmt.root, cxt);
    // Don't forget to deinitialize it at the end
    defer Executor.deinitDataNode(stmt.root, cxt);

    // Fetch input tuples one by one
    while (try Executor.execDataNode(stmt.root, cxt)) |tuple| {
        // And insert them into the output table
        _ = try heap.Table.init(
            cxt.storage_cache,
            .{
                .db = cxt.db_id,
                .table = stmt.table,
            },
        ).addOneTuple(tuple);
    }
}

/// Execute DELETE statement
pub fn executeDelete(stmt: Plan.Statement.Delete, cxt: *Context) !void {
    // Initialize the source data node
    try Executor.initDataNode(stmt.root, cxt);
    // Don't forget to deinitialize it at the end
    defer Executor.deinitDataNode(stmt.root, cxt);

    // Fetch input tuples one by one
    while (try Executor.execDataNode(stmt.root, cxt)) |tuple| {
        // And delete them from the table
        try heap.Table.init(
            cxt.storage_cache,
            .{
                .db = cxt.db_id,
                .table = stmt.table,
            },
        ).deleteTupleAt(tuple.extended().pos, cxt.tid);
    }
}

/// Execute TRUNCATE statement
pub fn executeTruncate(stmt: Plan.Statement.Truncate, cxt: *Context) !void {
    try heap.Table.init(
        cxt.storage_cache,
        .{
            .db = cxt.db_id,
            .table = stmt.table,
        },
    ).truncate();
}
