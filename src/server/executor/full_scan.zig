//! This is the executor for FullScan DataNode
//! This performs a full scan of a table

const std = @import("std");

const Context = @import("Context.zig");
const Plan = @import("../planner.zig").Plan;
const catalog = @import("../catalog.zig");
const heap = @import("../heap.zig");
const common = @import("common");
const oom = common.oom;
const Session = @import("../Session.zig");

/// The internal state of the FullScan
const State = struct {
    scanner: heap.Scanner,
};

/// Initialize the FullScan DataNode
pub fn init(plan: *Plan.DataNode, cxt: *Context) !void {
    const s = Session.get();
    std.debug.assert(plan.action == .full_scan);
    // Initialize the table scanner
    const table_id = plan.action.full_scan.table;
    try s.shared.lock_manager.lock(
        .{ .table = .{
            .db = s.db_id,
            .table = table_id,
        } },
        .read,
        s.thread_id,
    );

    const descr = s.catalog_cache.descr.getPtr(table_id).?;
    const scanner = try heap.Scanner.init(
        s.shared.storage_cache,
        .{ .db = s.db_id, .table = table_id },
        descr,
        cxt.snapshot,
    );
    // Create the internal state and attach it to plan
    const state = cxt.alloc.create(State) catch oom();
    state.* = .{ .scanner = scanner };
    plan.state = state;
}

/// Deinitialize the FullScan DataNode
pub fn deinit(plan: *Plan.DataNode, cxt: *Context) void {
    std.debug.assert(plan.action == .full_scan);
    // Destroy the internal state
    const state: *State = @ptrCast(@alignCast(plan.state.?));
    state.scanner.deinit();
    cxt.alloc.destroy(state);
}

/// Rewind FullScan DataNode to start from the first tuple again
pub fn rewind(plan: *Plan.DataNode) void {
    std.debug.assert(plan.action == .full_scan);
    const state: *State = @ptrCast(@alignCast(plan.state.?));
    state.scanner.rewind();
}

/// Fetch one tuple from FullScan DataNode
pub fn next(plan: *Plan.DataNode, cxt: *Context) !?common.MemTuple {
    std.debug.assert(plan.action == .full_scan);
    const state: *State = @ptrCast(@alignCast(plan.state.?));
    // Just fetch one tuple from the scanner
    if (try state.scanner.next(cxt.alloc)) |tuple| {
        return tuple;
    } else return null;
}
