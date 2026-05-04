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
const common = @import("common");
const heap = @import("../heap.zig");
const oom = common.oom;

pub const Executor = @This();
pub const Error = error{
    ExecutionError,
};

/// Execute a statement
pub fn execute(
    stmt: *const Plan.Statement,
    cxt: *Context,
) !void {
    switch (stmt.*) {
        .create_table => try ddl.executeCreateTable(stmt.create_table, cxt),
        .insert => try modify.executeInsert(stmt.insert, cxt),
        .select => try executeSelect(stmt.select, cxt),
        .truncate => try modify.executeTruncate(stmt.truncate, cxt),
        .delete => try modify.executeDelete(stmt.delete, cxt),
        .update => try modify.executeUpdate(stmt.update, cxt),
        .drop_table => unreachable,
    }
}

/// Execute a SELECT statement
fn executeSelect(
    stmt: Plan.Statement.Select,
    cxt: *Context,
) !void {
    // Initialize the data node
    try initDataNode(stmt.root, cxt);
    // Don't forget to free it at the end
    defer deinitDataNode(stmt.root, cxt);

    // Send the descriptor to the client
    try cxt.sender.send(.{ .tuple_descriptor = stmt.root.descr });

    // Fetch tuples one by one
    while (try execDataNode(stmt.root, cxt)) |tuple| {
        // And send them to the client
        try cxt.sender.send(.{ .tuple = tuple });
    }
}

/// Initialize any DataNode. Call this at the start of execution.
pub fn initDataNode(plan: *Plan.DataNode, cxt: *Context) Error!void {
    const r = switch (plan.action) {
        .full_scan => full_scan.init(plan, cxt),
        .values => values.init(plan, cxt),
        .project => project.init(plan, cxt),
        .filter => filter.init(plan, cxt),
    };
    r catch |err| {
        cxt.sender.log(
            cxt.alloc,
            "ERROR: {} during Plan init",
            .{err},
        ) catch {};
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
    }
}

/// Fetch one tuple fron data node. Can be used like an iterator.
pub fn execDataNode(plan: *Plan.DataNode, cxt: *Context) Error!?common.MemTuple {
    const r = switch (plan.action) {
        .full_scan => full_scan.next(plan, cxt),
        .values => values.next(plan, cxt),
        .project => project.next(plan, cxt),
        .filter => filter.next(plan, cxt),
    };
    return r catch |err| {
        cxt.sender.log(
            cxt.alloc,
            "ERROR: {} during execution",
            .{err},
        ) catch {};
        return Error.ExecutionError;
    };
}
