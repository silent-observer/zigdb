//! Executor for table-modifying statements

const Context = @import("Context.zig");
const Plan = @import("../planner.zig").Plan;
const catalog = @import("../catalog.zig");
const ids = common.ids;
const heap = @import("../heap.zig");
const common = @import("common");
const scalar = @import("scalar.zig");
const Executor = @import("Executor.zig");
const oom = common.oom;

/// Execute INSERT statement
pub fn executeInsert(stmt: Plan.Statement.Insert, cxt: *Context) !void {
    // We need a real transaction to write data
    cxt.s.shared.transaction_log.startRealTransaction(&cxt.s.current_tid);
    // Initialize the source data node
    try Executor.initDataNode(stmt.root, cxt);
    // Don't forget to deinitialize it at the end
    defer Executor.deinitDataNode(stmt.root, cxt);

    // Fetch input tuples one by one
    while (try Executor.execDataNode(stmt.root, cxt)) |tuple| {
        // And insert them into the output table
        _ = try heap.Table.init(
            cxt.s.shared.storage_cache,
            .{
                .db = cxt.s.db_id,
                .table = stmt.table,
            },
        ).addOneTuple(tuple);
    }
}

/// Execute DELETE statement
pub fn executeDelete(stmt: Plan.Statement.Delete, cxt: *Context) !void {
    // We need a real transaction to write data
    cxt.s.shared.transaction_log.startRealTransaction(&cxt.s.current_tid);
    // Initialize the source data node
    try Executor.initDataNode(stmt.root, cxt);
    // Don't forget to deinitialize it at the end
    defer Executor.deinitDataNode(stmt.root, cxt);

    // Fetch input tuples one by one
    while (try Executor.execDataNode(stmt.root, cxt)) |tuple| {
        // And delete them from the table
        try heap.Table.init(
            cxt.s.shared.storage_cache,
            .{
                .db = cxt.s.db_id,
                .table = stmt.table,
            },
        ).deleteTupleAt(tuple.extended().pos, cxt.s.current_tid.real);
    }
}

/// Execute UPDATE statement
pub fn executeUpdate(stmt: Plan.Statement.Update, cxt: *Context) !void {
    // We need a real transaction to write data
    cxt.s.shared.transaction_log.startRealTransaction(&cxt.s.current_tid);
    // Initialize the source data node
    try Executor.initDataNode(stmt.root, cxt);
    // Don't forget to deinitialize it at the end
    defer Executor.deinitDataNode(stmt.root, cxt);

    // Temporary tuple for updates
    const temp_tuple = cxt.alloc.alloc(
        common.Value,
        stmt.root.descr.attrs.len,
    ) catch oom();
    defer cxt.alloc.free(temp_tuple);

    // Fetch input tuples one by one
    while (try Executor.execDataNode(stmt.root, cxt)) |tuple| {
        const table_id = ids.FullTableId{
            .db = cxt.s.db_id,
            .table = stmt.table,
        };
        // Delete them from the table
        try heap.Table.init(cxt.s.shared.storage_cache, table_id)
            .deleteTupleAt(tuple.extended().pos, cxt.s.current_tid.real);
        // Fill the temporary tuple with them
        for (0..tuple.len()) |i| {
            temp_tuple[i] = tuple.getValue(i);
        }
        // Run the updates
        for (stmt.cols, stmt.vals) |col, val| {
            temp_tuple[col] = scalar.eval(&val, tuple);
        }
        // Build the new tuple
        var b = common.MemTuple.Builder.init(cxt.alloc, stmt.root.descr);
        for (temp_tuple) |v| {
            b.pushValue(v);
        }
        b.addExtended(.{
            .xmin = cxt.s.current_tid.real,
            .xmax = .invalid,
            .pos = .none,
        });
        const new_tuple = b.finalize();
        // Insert it back into the table
        _ = try heap.Table.init(cxt.s.shared.storage_cache, table_id)
            .addOneTuple(new_tuple);
    }
}

/// Execute TRUNCATE statement
pub fn executeTruncate(stmt: Plan.Statement.Truncate, cxt: *Context) !void {
    try heap.Table.init(
        cxt.s.shared.storage_cache,
        .{
            .db = cxt.s.db_id,
            .table = stmt.table,
        },
    ).truncate();
}
