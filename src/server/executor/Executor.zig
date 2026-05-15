//! This is the module that actually executes the plan.
//! Requires executor Context to do anything.

const std = @import("std");
const Context = @import("Context.zig");
const Plan = @import("../planner.zig").Plan;
const ddl = @import("ddl.zig");
const modify = @import("modify.zig");
const full_scan = @import("full_scan.zig");
const values = @import("values.zig");
const project = @import("project.zig");
const filter = @import("filter.zig");
const nested_loop = @import("nested_loop.zig");
const union_all = @import("union_all.zig");
const srf = @import("srf.zig");
const common = @import("common");
const heap = @import("../heap.zig");
const oom = common.oom;
const Logger = @import("../Logger.zig");
const Session = @import("../Session.zig");

pub const Executor = @This();
pub const Error = error{
    ExecutionError,
};

/// Execute a statement
pub fn execute(
    stmt: *const Plan.Statement,
    cxt: *Context,
) ![]const u8 {
    return switch (stmt.*) {
        .create_table => try ddl.executeCreateTable(stmt.create_table, cxt),
        .drop_table => try ddl.executeDropTable(stmt.drop_table),
        .insert => try modify.executeInsert(stmt.insert, cxt),
        .select => try executeSelect(stmt.select, cxt),
        .truncate => try modify.executeTruncate(stmt.truncate),
        .delete => try modify.executeDelete(stmt.delete, cxt),
        .update => try modify.executeUpdate(stmt.update, cxt),
        .begin => try executeBegin(),
        .commit => try executeCommit(),
        .rollback => try executeRollback(),
    };
}

/// Execute a SELECT statement
fn executeSelect(
    stmt: Plan.Statement.Select,
    cxt: *Context,
) ![]const u8 {
    const s = Session.get();
    // Initialize the data node
    try initDataNode(stmt.root, cxt);
    // Don't forget to free it at the end
    defer deinitDataNode(stmt.root, cxt);

    // Send the descriptor to the client
    try s.sender.send(.{ .tuple_descriptor = stmt.root.descr });

    // Fetch tuples one by one
    while (try execDataNode(stmt.root, cxt)) |tuple| {
        // And send them to the client
        const m = common.network.Message.makeTuple(tuple, cxt.alloc);
        defer cxt.alloc.free(m.tuple.data);
        try s.sender.send(m);
    }

    // No success message
    return "";
}

/// Execute a BEGIN statement
fn executeBegin() ![]const u8 {
    const s = Session.get();
    // Make sure we're not in a transaction
    if (s.explicit_transaction != .inactive) {
        Logger.err("Already in transaction", .{});
        return Error.ExecutionError;
    }
    try s.shared.transaction_log.startRealTransaction(&s.current_tid);
    s.explicit_transaction = .active;

    return "BEGIN";
}

/// Execute a COMMIT statement
fn executeCommit() ![]const u8 {
    const s = Session.get();
    // Make sure we're in an active transaction
    switch (s.explicit_transaction) {
        .active => {},
        .inactive => {
            Logger.err("Not in transaction", .{});
            return Error.ExecutionError;
        },
        .broken => {
            Logger.err("Cannot commit because of previous errors", .{});
            return Error.ExecutionError;
        },
    }

    try s.shared.transaction_log.endTransaction(s.current_tid, .committed);
    s.current_tid = .virtual;
    s.explicit_transaction = .inactive;
    try s.shared.lock_manager.unlockAll(s.thread_id);

    return "COMMIT";
}

/// Execute a ROLLBACK statement
fn executeRollback() ![]const u8 {
    const s = Session.get();
    // Make sure we're in a transaction
    switch (s.explicit_transaction) {
        .active, .broken => {},
        .inactive => {
            Logger.err("Not in transaction", .{});
            return Error.ExecutionError;
        },
    }

    try s.shared.transaction_log.endTransaction(s.current_tid, .aborted);
    s.current_tid = .virtual;
    s.explicit_transaction = .inactive;
    try s.shared.lock_manager.unlockAll(s.thread_id);

    return "ROLLBACK";
}

/// Initialize any DataNode. Call this at the start of execution.
pub fn initDataNode(plan: *Plan.DataNode, cxt: *Context) Error!void {
    const r = switch (plan.action) {
        .full_scan => full_scan.init(plan, cxt),
        .values => values.init(plan, cxt),
        .project => project.init(plan, cxt),
        .filter => filter.init(plan, cxt),
        .nested_loop => nested_loop.init(plan, cxt),
        .union_all => union_all.init(plan, cxt),
        .func => srf.init(plan, cxt),
    };
    r catch |err| {
        Logger.err("{} during Plan init", .{err});
        return Error.ExecutionError;
    };
}

/// Deinitialize any DataNode. Call this at the end of execution.
pub fn deinitDataNode(plan: *Plan.DataNode, cxt: *Context) void {
    switch (plan.action) {
        .full_scan => return full_scan.deinit(plan, cxt),
        .values => return values.deinit(plan, cxt),
        .project => return project.deinit(plan, cxt),
        .filter => return filter.deinit(plan, cxt),
        .nested_loop => return nested_loop.deinit(plan, cxt),
        .union_all => return union_all.deinit(plan, cxt),
        .func => return srf.deinit(plan, cxt),
    }
}

/// Rewind the DataNode, causing it to start from the start of its data.
pub fn rewindDataNode(plan: *Plan.DataNode) Error!void {
    const r = switch (plan.action) {
        .full_scan => full_scan.rewind(plan),
        .values => values.rewind(plan),
        .project => project.rewind(plan),
        .filter => filter.rewind(plan),
        .nested_loop => nested_loop.rewind(plan),
        .union_all => union_all.rewind(plan),
        .func => srf.rewind(plan),
    };
    r catch |err| {
        Logger.err("{} during Plan rewind", .{err});
        return Error.ExecutionError;
    };
}

/// Fetch one tuple fron data node. Can be used like an iterator.
pub fn execDataNode(plan: *Plan.DataNode, cxt: *Context) Error!?common.MemTuple {
    const r = switch (plan.action) {
        .full_scan => full_scan.next(plan, cxt),
        .values => values.next(plan, cxt),
        .project => project.next(plan, cxt),
        .filter => filter.next(plan, cxt),
        .nested_loop => nested_loop.next(plan, cxt),
        .union_all => union_all.next(plan, cxt),
        .func => srf.next(plan, cxt),
    };
    return r catch |err| {
        Logger.err("{} during execution", .{err});
        return Error.ExecutionError;
    };
}
