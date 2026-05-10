//! This is the executor for NestedLoop DataNode
//! This performs a nested loop join, getting the whole
//! right child's data for each tuple from left child,
//! and checking the condition for each combination.
const std = @import("std");

const Context = @import("Context.zig");
const Plan = @import("../planner.zig").Plan;
const common = @import("common");
const oom = common.oom;
const Executor = @import("Executor.zig");
const scalar = @import("scalar.zig");

/// The internal state of the FullScan
const State = struct {
    left_tuple: ?common.MemTuple = null,
    found_match: bool = false,
};

/// Initialize the NestedLoop DataNode
pub fn init(plan: *Plan.DataNode, cxt: *Context) !void {
    std.debug.assert(plan.action == .nested_loop);
    // Simply recurse to children
    try Executor.initDataNode(plan.action.nested_loop.lhs, cxt);
    try Executor.initDataNode(plan.action.nested_loop.rhs, cxt);

    const state = cxt.alloc.create(State) catch oom();
    state.* = .{};
    plan.state = state;
}

/// Initialize the NestedLoop DataNode
pub fn deinit(plan: *Plan.DataNode, cxt: *Context) void {
    std.debug.assert(plan.action == .nested_loop);
    // Simply recurse to children
    Executor.deinitDataNode(plan.action.nested_loop.lhs, cxt);
    Executor.deinitDataNode(plan.action.nested_loop.rhs, cxt);

    const state: *State = @ptrCast(@alignCast(plan.state.?));
    if (state.left_tuple) |lt|
        lt.deinit(cxt.alloc);
    cxt.alloc.destroy(state);
}

/// Rewind NestedLoop DataNode to start from the first tuple again
pub fn rewind(plan: *Plan.DataNode) !void {
    std.debug.assert(plan.action == .nested_loop);
    const state: *State = @ptrCast(@alignCast(plan.state.?));
    state.left_tuple = null;
    state.found_match = false;

    try Executor.rewindDataNode(plan.action.nested_loop.lhs);
    try Executor.rewindDataNode(plan.action.nested_loop.rhs);
}

/// Fetch one tuple from NestedLoop DataNode
pub fn next(plan: *Plan.DataNode, cxt: *Context) !?common.MemTuple {
    const state: *State = @ptrCast(@alignCast(plan.state.?));
    while (true) {
        // Fetch new left tuple, if needed
        if (state.left_tuple == null) {
            state.left_tuple = try Executor.execDataNode(plan.action.nested_loop.lhs, cxt);
            if (state.left_tuple == null)
                // The left child is done, we are done too
                return null;
            state.found_match = false;
            try Executor.rewindDataNode(plan.action.nested_loop.rhs);
        }

        // Try fetch new right tuple
        const right_tuple = try Executor.execDataNode(plan.action.nested_loop.rhs, cxt);
        if (right_tuple == null) {
            // The right child is done, we should rewind it.
            try Executor.rewindDataNode(plan.action.nested_loop.rhs);
            // Reset the left tuple to fetch the new one (but remember the previous one)
            const left_tuple = state.left_tuple.?;
            state.left_tuple = null;

            // Some join types require us to return a tuple here
            switch (plan.action.nested_loop.op) {
                .anti_semi => {
                    // Return left tuple if we didn't find a match for it
                    if (!state.found_match)
                        return left_tuple
                    else
                        continue;
                },
                .left => {
                    if (state.found_match)
                        // Already found legitimate matches, no need for NULL tuple
                        continue;
                    // Fill the right tuple with nulls
                    var b = common.MemTuple.Builder.init(cxt.alloc, plan.descr);
                    for (0..state.left_tuple.?.len()) |i| {
                        b.pushValue(state.left_tuple.?.getValue(i));
                    }
                    for (0..plan.action.nested_loop.rhs.descr.attrs.len) |_| {
                        b.pushValue(.null);
                    }
                    if (plan.descr.has_extended)
                        b.addExtended(state.left_tuple.?.extended().*);
                    state.left_tuple = null;
                    return b.finalize();
                },
                .cross, .inner, .semi => continue,
            }
        }

        const result_tuple = switch (plan.action.nested_loop.op) {
            .cross, .inner, .left => tuple: {
                // We are ready to build combined tuple
                var b = common.MemTuple.Builder.init(cxt.alloc, plan.descr);
                for (0..state.left_tuple.?.len()) |i| {
                    b.pushValue(state.left_tuple.?.getValue(i));
                }
                for (0..right_tuple.?.len()) |i| {
                    b.pushValue(right_tuple.?.getValue(i));
                }
                if (plan.descr.has_extended)
                    b.addExtended(state.left_tuple.?.extended().*);
                break :tuple b.finalize();
            },
            .semi, .anti_semi => state.left_tuple.?,
        };

        // Check the condition
        const cond = if (plan.action.nested_loop.cond) |cond|
            try scalar.eval(cond, result_tuple, cxt)
        else
            common.Value{ .boolean = true };
        // Return the tuple if condition is true, skip if false
        const cond_val = switch (cond) {
            .null => false,
            .boolean => |cond_val| cond_val,
            else => unreachable,
        };

        if (cond_val) {
            state.found_match = true;
            switch (plan.action.nested_loop.op) {
                .inner, .left, .cross => return result_tuple,
                .semi => {
                    state.left_tuple = null;
                    return result_tuple;
                },
                .anti_semi => {
                    state.left_tuple = null;
                    continue;
                },
            }
        }
    }
}
