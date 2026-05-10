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
        const t = if (stmt.toast_table) |toast_table_id| t: {
            var b = common.MemTuple.Builder.init(cxt.alloc, tuple.ptr.h.descr);
            for (0..tuple.len()) |i| {
                const value = tuple.getValue(i);
                b.pushValue(try toaster.toastValue(value, toast_table_id, cxt.alloc));
            }
            b.addExtended(tuple.extended().*);
            break :t b.finalize();
        } else tuple;
        // And insert them into the output table
        _ = try heap.Table.init(
            s.shared.storage_cache,
            .{
                .db = s.db_id,
                .table = stmt.table,
            },
        ).addOneTuple(t);
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
        ).deleteTupleAt(tuple.extended().pos, s.current_tid.real);
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

    // Temporary tuple for updates
    const temp_tuple = cxt.alloc.alloc(
        common.Value,
        stmt.root.descr.attrs.len,
    ) catch oom();
    defer cxt.alloc.free(temp_tuple);

    // Fetch input tuples one by one
    var counter: usize = 0;
    while (try Executor.execDataNode(stmt.root, cxt)) |tuple| {
        const table_id = ids.FullTableId{
            .db = s.db_id,
            .table = stmt.table,
        };
        // Delete them from the table
        try heap.Table.init(s.shared.storage_cache, table_id)
            .deleteTupleAt(tuple.extended().pos, s.current_tid.real);
        // Fill the temporary tuple with them
        for (0..tuple.len()) |i| {
            temp_tuple[i] = tuple.getValue(i);
        }
        // Run the updates
        for (stmt.cols, stmt.vals) |col, val| {
            temp_tuple[col] = try scalar.eval(&val, tuple, cxt);
        }
        // Build the new tuple
        var b = common.MemTuple.Builder.init(cxt.alloc, stmt.root.descr);
        for (temp_tuple) |v| {
            if (stmt.toast_table) |toast_table_id|
                b.pushValue(try toaster.toastValue(v, toast_table_id, cxt.alloc))
            else
                b.pushValue(v);
        }
        b.addExtended(.{
            .xmin = s.current_tid.real,
            .xmax = .invalid,
            .pos = .none,
        });
        const new_tuple = b.finalize();
        // Insert it back into the table
        _ = try heap.Table.init(s.shared.storage_cache, table_id)
            .addOneTuple(new_tuple);
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
