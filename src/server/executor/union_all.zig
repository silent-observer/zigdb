//! This is the executor for UnionAll DataNode
//! This combines outputs of several child nodes in order

const std = @import("std");

const Context = @import("Context.zig");
const Plan = @import("../planner.zig").Plan;
const common = @import("common");
const oom = common.oom;
const Executor = @import("Executor.zig");

/// Internal state for Values DataNode
const State = struct {
    index: usize,
};

/// Initialize the UnionAll DataNode
pub fn init(plan: *Plan.DataNode, cxt: *Context) !void {
    std.debug.assert(plan.action == .union_all);
    // Create internal state
    const state = cxt.alloc.create(State) catch oom();
    // Starting index is 0
    state.* = .{ .index = 0 };
    plan.state = state;
    for (plan.action.union_all.inputs) |*input|
        try Executor.initDataNode(input, cxt);
}

/// Deinitialize the UnionAll DataNode
pub fn deinit(plan: *Plan.DataNode, cxt: *Context) void {
    std.debug.assert(plan.action == .union_all);
    // Destroy the internal state
    const state: *State = @ptrCast(@alignCast(plan.state.?));
    cxt.alloc.destroy(state);
    for (plan.action.union_all.inputs) |*input|
        Executor.deinitDataNode(input, cxt);
}

/// Rewind UnionAll DataNode to start from the first tuple again
pub fn rewind(plan: *Plan.DataNode) !void {
    std.debug.assert(plan.action == .union_all);
    const state: *State = @ptrCast(@alignCast(plan.state.?));
    state.index = 0;
    for (plan.action.union_all.inputs) |*input|
        try Executor.rewindDataNode(input);
}

/// Fetch one tuple from UnionAll DataNode
pub fn next(plan: *Plan.DataNode, cxt: *Context) !?common.MemTuple {
    std.debug.assert(plan.action == .union_all);
    const state: *State = @ptrCast(@alignCast(plan.state.?));
    while (state.index < plan.action.union_all.inputs.len) {
        const child = &plan.action.union_all.inputs[state.index];
        if (try Executor.execDataNode(child, cxt)) |tuple|
            return tuple;
        // Go to the next child
        state.index += 1;
    }
    // We are done
    return null;
}
