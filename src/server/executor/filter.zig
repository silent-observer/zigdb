//! This is the executor for Filter DataNode
//! This performs filtering, evaluating a condition
//! for every tuple that passes through it, and only returning
//! tuples that match the condition.
//!
//! This executor has no special internal state.
const std = @import("std");

const Context = @import("Context.zig");
const Plan = @import("../planner.zig").Plan;
const common = @import("common");
const oom = common.oom;
const Executor = @import("Executor.zig");
const scalar = @import("scalar.zig");

/// Initialize the Filter DataNode
pub fn init(plan: *Plan.DataNode, cxt: *Context) !void {
    std.debug.assert(plan.action == .filter);
    // Simply recurse to child
    try Executor.initDataNode(plan.action.filter.input, cxt);
}

/// Initialize the Filter DataNode
pub fn deinit(plan: *Plan.DataNode, cxt: *Context) void {
    std.debug.assert(plan.action == .filter);
    // Simply recurse to child
    Executor.deinitDataNode(plan.action.filter.input, cxt);
}

/// Rewind Filter DataNode to start from the first tuple again
pub fn rewind(plan: *Plan.DataNode) !void {
    std.debug.assert(plan.action == .filter);
    // Simply recurse to child
    try Executor.rewindDataNode(plan.action.filter.input);
}

/// Fetch one tuple from Filter DataNode
pub fn next(plan: *Plan.DataNode, cxt: *Context) !?common.MemTuple {
    std.debug.assert(plan.action == .filter);
    // Get one tuple from child
    while (try Executor.execDataNode(plan.action.filter.input, cxt)) |input| {
        // Check the condition
        const cond = try scalar.eval(plan.action.filter.condition, input, cxt);
        // Return the tuple if condition is true, skip if false
        const b = switch (cond) {
            .null => false,
            .boolean => |b| b,
            else => unreachable,
        };
        if (b)
            return input;
    }
    // If the child is done, we are done too
    return null;
}
