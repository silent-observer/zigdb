//! Executor for table-modifying statements

const std = @import("std");

const Context = @import("Context.zig");
const Plan = @import("../planner.zig").Plan;
const catalog = @import("../catalog.zig");
const ids = common.ids;
const heap = @import("../heap.zig");
const common = @import("common");
const scalar = @import("scalar.zig");
const Executor = @import("Executor.zig");
const oom = common.oom;
const Session = @import("../Session.zig");
const toaster = @import("../toaster.zig");

/// Execute INSERT statement
pub fn executeInsert(stmt: Plan.Statement.Insert, cxt: *Context) ![]const u8 {
    const s = Session.get();
    // We need a real transaction to write data
    try s.shared.transaction_log.startRealTransaction(&s.current_tid);
    // Get a write lock on the table
    try s.shared.lock_manager.lock(
        .{ .table = .{
            .db = s.db_id,
            .table = stmt.table,
        } },
        .write,
        s.thread_id,
    );
    // Initialize the source data node
    try Executor.initDataNode(stmt.root, cxt);
    // Don't forget to deinitialize it at the end
    defer Executor.deinitDataNode(stmt.root, cxt);

    // Fetch input tuples one by one
    var counter: usize = 0;
    while (try Executor.execDataNode(stmt.root, cxt)) |tuple| {
        // Toast attributes if needed
        if (stmt.toast_table) |toast_table_id| {
            for (tuple.values) |*v| {
                v.* = try toaster.toastValue(v.*, toast_table_id, cxt.alloc);
            }
        }
        // And insert them into the output table
        _ = try heap.Table.init(
            s.shared.storage_cache,
            .{
                .db = s.db_id,
                .table = stmt.table,
            },
        ).addOneTuple(tuple, cxt.alloc);
        counter += 1;
    }

    return std.fmt.allocPrint(cxt.alloc, "INSERT {}", .{counter});
}

/// Execute DELETE statement
pub fn executeDelete(stmt: Plan.Statement.Delete, cxt: *Context) ![]const u8 {
    const s = Session.get();
    // We need a real transaction to write data
    try s.shared.transaction_log.startRealTransaction(&s.current_tid);
    // Get a write lock on the table
    try s.shared.lock_manager.lock(
        .{ .table = .{
            .db = s.db_id,
            .table = stmt.table,
        } },
        .write,
        s.thread_id,
    );
    // Initialize the source data node
    try Executor.initDataNode(stmt.root, cxt);
    // Don't forget to deinitialize it at the end
    defer Executor.deinitDataNode(stmt.root, cxt);

    // Fetch input tuples one by one
    var counter: usize = 0;
    while (try Executor.execDataNode(stmt.root, cxt)) |tuple| {
        // And delete them from the table
        try heap.Table.init(
            s.shared.storage_cache,
            .{
                .db = s.db_id,
                .table = stmt.table,
            },
        ).deleteTupleAt(tuple.ext.?.pos, s.current_tid.real);
        counter += 1;
    }

    return std.fmt.allocPrint(cxt.alloc, "DELETE {}", .{counter});
}

/// Execute UPDATE statement
pub fn executeUpdate(stmt: Plan.Statement.Update, cxt: *Context) ![]const u8 {
    const s = Session.get();
    // We need a real transaction to write data
    try s.shared.transaction_log.startRealTransaction(&s.current_tid);
    // Get a write lock on the table
    try s.shared.lock_manager.lock(
        .{ .table = .{
            .db = s.db_id,
            .table = stmt.table,
        } },
        .write,
        s.thread_id,
    );
    // Initialize the source data node
    try Executor.initDataNode(stmt.root, cxt);
    // Don't forget to deinitialize it at the end
    defer Executor.deinitDataNode(stmt.root, cxt);

    // Fetch input tuples one by one
    var counter: usize = 0;
    while (try Executor.execDataNode(stmt.root, cxt)) |tuple| {
        const table_id = ids.FullTableId{
            .db = s.db_id,
            .table = stmt.table,
        };
        // Delete them from the table
        try heap.Table.init(s.shared.storage_cache, table_id)
            .deleteTupleAt(tuple.ext.?.pos, s.current_tid.real);
        // Run the updates
        for (stmt.cols, stmt.vals) |col, val| {
            tuple.values[col] = try scalar.eval(&val, tuple, cxt);
        }
        // Insert it back into the table
        _ = try heap.Table.init(s.shared.storage_cache, table_id)
            .addOneTuple(tuple, cxt.alloc);
        counter += 1;
    }

    return std.fmt.allocPrint(cxt.alloc, "UPDATE {}", .{counter});
}

/// Execute TRUNCATE statement
pub fn executeTruncate(stmt: Plan.Statement.Truncate) ![]const u8 {
    const s = Session.get();
    // Get an exclusive lock on the table
    try s.shared.lock_manager.lock(
        .{ .table = .{
            .db = s.db_id,
            .table = stmt.table,
        } },
        .exclusive,
        s.thread_id,
    );
    // Perform actual truncation
    try heap.Table.init(
        s.shared.storage_cache,
        .{
            .db = s.db_id,
            .table = stmt.table,
        },
    ).truncate();

    if (stmt.toast_table) |toast_table_id| {
        try heap.Table.init(
            s.shared.storage_cache,
            .{
                .db = s.db_id,
                .table = toast_table_id,
            },
        ).truncate();
    }

    return "TRUNCATE";
}
