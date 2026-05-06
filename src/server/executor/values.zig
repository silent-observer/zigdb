//! This is the executor for Values DataNode
//! This returns a set of rows specified in the query itself

const std = @import("std");

const Context = @import("Context.zig");
const Plan = @import("../planner.zig").Plan;
const common = @import("common");
const oom = common.oom;

/// Internal state for Values DataNode
const State = struct {
    index: usize,
};

/// Initialize the Values DataNode
pub fn init(plan: *Plan.DataNode, cxt: *Context) void {
    std.debug.assert(plan.action == .values);
    // Create internal state
    const state = cxt.alloc.create(State) catch oom();
    // Starting index is 0
    state.* = .{ .index = 0 };
    plan.state = state;
}

/// Deinitialize the Values DataNode
pub fn deinit(plan: *Plan.DataNode, cxt: *Context) void {
    std.debug.assert(plan.action == .values);
    // Destroy the internal state
    const state: *State = @ptrCast(@alignCast(plan.state.?));
    cxt.alloc.destroy(state);
}

/// Fetch one tuple from Values DataNode
pub fn next(plan: *Plan.DataNode, cxt: *Context) ?common.MemTuple {
    std.debug.assert(plan.action == .values);
    _ = cxt;
    const state: *State = @ptrCast(@alignCast(plan.state.?));
    defer state.index += 1; // Increment the index at the end
    if (state.index < plan.action.values.data.len)
        // Return a tuple
        return plan.action.values.data[state.index]
    else
        // We are done
        return null;
}
