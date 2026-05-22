//! This is the executor for IndexScan DataNode
//! This performs a full scan of a table

const std = @import("std");

const Context = @import("Context.zig");
const Plan = @import("../planner.zig").Plan;
const catalog = @import("../catalog.zig");
const heap = @import("../heap.zig");
const btree = @import("../btree.zig");
const common = @import("common");
const oom = common.oom;
const Session = @import("../Session.zig");

/// The internal state of the IndexScan
const State = struct {
    index_walker: btree.Walker,
    heap_scanner: heap.Scanner,
    started: bool,
    ended: bool,
};

/// Initialize the IndexScan DataNode
pub fn init(plan: *Plan.DataNode, cxt: *Context) !void {
    const s = Session.get();
    std.debug.assert(plan.action == .index_scan);
    // Initialize the table scanner
    const index_id = plan.action.index_scan.index;
    const table_id = plan.action.index_scan.table;
    try s.shared.lock_manager.lock(
        .{ .table = .{
            .db = s.db_id,
            .table = table_id,
        } },
        .read,
        s.thread_id,
    );
    try s.shared.lock_manager.lock(
        .{ .table = .{
            .db = s.db_id,
            .table = index_id,
        } },
        .read,
        s.thread_id,
    );

    const descr = s.catalog_cache.descr.getPtr(table_id).?;
    const heap_scanner = try heap.Scanner.init(
        s.shared.storage_cache,
        .{ .db = s.db_id, .table = table_id },
        descr,
        cxt.snapshot,
    );
    const index_walker = try btree.Walker.init(
        cxt.alloc,
        s.shared.storage_cache,
        .{ .db = s.db_id, .table = index_id },
        plan.action.index_scan.index_descr,
    );

    // Create the internal state and attach it to plan
    const state = cxt.alloc.create(State) catch oom();
    state.* = .{
        .index_walker = index_walker,
        .heap_scanner = heap_scanner,
        .started = false,
        .ended = false,
    };
    plan.state = state;
}

/// Deinitialize the IndexScan DataNode
pub fn deinit(plan: *Plan.DataNode, cxt: *Context) void {
    std.debug.assert(plan.action == .index_scan);
    // Destroy the internal state
    const state: *State = @ptrCast(@alignCast(plan.state.?));
    state.heap_scanner.deinit();
    state.index_walker.deinit();
    cxt.alloc.destroy(state);
}

/// Rewind IndexScan DataNode to start from the first tuple again
pub fn rewind(plan: *Plan.DataNode) void {
    std.debug.assert(plan.action == .index_scan);
    const state: *State = @ptrCast(@alignCast(plan.state.?));
    state.started = false;
    state.ended = false;
}

/// Fetch one tuple from IndexScan DataNode
pub fn next(plan: *Plan.DataNode, cxt: *Context) !?common.MemTuple {
    std.debug.assert(plan.action == .index_scan);
    const state: *State = @ptrCast(@alignCast(plan.state.?));
    if (state.ended) return null;
    const index_scan = plan.action.index_scan;
    // If we haven't started the scan yet
    if (!state.started) {
        state.started = true;
        // Find the lower bound in the index
        const found = try state.index_walker.search(index_scan.lower);
        // If we found the exact match and lower bound is exclusive, skip it
        if (found and !index_scan.lower_inclusive) {
            // Advance until we are past the block of equal values
            while (try state.index_walker.advanceForward()) {
                // Fetch one tuple
                const curr_compact = state.index_walker.curr().?;
                const curr = try curr_compact.uncompact(
                    index_scan.index_descr,
                    cxt.alloc,
                );
                // Compare with lower bound
                const o = common.Value.orderMany(
                    curr.values,
                    index_scan.lower,
                    index_scan.index_descr,
                );
                // We found the actual start of data
                if (o == .gt)
                    break;
            }
        }
    }

    // Fetch one key from the index
    const curr_compact = state.index_walker.curr();
    if (curr_compact == null) return null;
    const curr = try curr_compact.?.uncompact(
        index_scan.index_descr,
        cxt.alloc,
    );
    // Compare with the upper bound
    const o = common.Value.orderMany(
        curr.values,
        index_scan.upper,
        index_scan.index_descr,
    );
    // Passed the upper bound
    if (o == .gt or o == .eq and !index_scan.upper_inclusive)
        return null;

    // Advance the index walker
    if (!try state.index_walker.advanceForward())
        state.ended = true;

    // Now fetch the full tuple from the heap table
    state.heap_scanner.seek(curr_compact.?.getHeader().pos);
    return try state.heap_scanner.next(cxt.alloc);
}
