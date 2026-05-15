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
                    std.debug.assert(plan.action.nested_loop.output_format == .left_only);
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
                    var values = std.ArrayList(common.Value)
                        .initCapacity(cxt.alloc, plan.descr.len()) catch oom();

                    const rhs_len = plan.action.nested_loop.rhs.descr.len();
                    switch (plan.action.nested_loop.output_format) {
                        .left_right => {
                            values.appendSliceAssumeCapacity(left_tuple.values);
                            values.appendNTimesAssumeCapacity(.null, rhs_len);
                        },
                        .right_left => {
                            values.appendNTimesAssumeCapacity(.null, rhs_len);
                            values.appendSliceAssumeCapacity(left_tuple.values);
                        },
                        .left_only => unreachable,
                    }
                    return common.MemTuple{
                        .descr = plan.descr,
                        .ext = left_tuple.ext,
                        .values = values.toOwnedSliceAssert(),
                    };
                },
                .cross, .inner, .semi => continue,
            }
        }

        const cond_tuple = tuple: {
            // We are ready to build combined tuple
            const cond_descr = plan.action.nested_loop.cond_descr;
            var values = std.ArrayList(common.Value)
                .initCapacity(cxt.alloc, cond_descr.len()) catch oom();
            switch (plan.action.nested_loop.cond_format) {
                .left_right => {
                    values.appendSliceAssumeCapacity(state.left_tuple.?.values);
                    values.appendSliceAssumeCapacity(right_tuple.?.values);
                },
                .right_left => {
                    values.appendSliceAssumeCapacity(right_tuple.?.values);
                    values.appendSliceAssumeCapacity(state.left_tuple.?.values);
                },
                .left_only => unreachable,
            }
            break :tuple common.MemTuple{
                .descr = cond_descr,
                .values = values.toOwnedSlice(cxt.alloc) catch oom(),
                .ext = if (state.left_tuple.?.ext) |e|
                    e
                else
                    right_tuple.?.ext,
            };
        };

        // Check the condition
        const cond = if (plan.action.nested_loop.cond) |cond|
            try scalar.eval(cond, cond_tuple, cxt)
        else
            common.Value{ .boolean = true };
        // Return the tuple if condition is true, skip if false
        const cond_val = switch (cond) {
            .null => false,
            .boolean => |cond_val| cond_val,
            else => unreachable,
        };

        if (cond_val) {
            var values = std.ArrayList(common.Value)
                .initCapacity(cxt.alloc, plan.descr.len()) catch oom();
            switch (plan.action.nested_loop.output_format) {
                .left_right => {
                    values.appendSliceAssumeCapacity(state.left_tuple.?.values);
                    values.appendSliceAssumeCapacity(right_tuple.?.values);
                },
                .right_left => {
                    values.appendSliceAssumeCapacity(right_tuple.?.values);
                    values.appendSliceAssumeCapacity(state.left_tuple.?.values);
                },
                .left_only => {
                    values.appendSliceAssumeCapacity(state.left_tuple.?.values);
                },
            }
            const result_tuple = common.MemTuple{
                .descr = plan.descr,
                .ext = if (state.left_tuple.?.ext) |e|
                    e
                else
                    right_tuple.?.ext,
                .values = values.toOwnedSliceAssert(),
            };

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
