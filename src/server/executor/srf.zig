//! This is the executor for Set-Returning function DataNode
//! This executes a function, returning several tuples.
//!
//! This executor has a unique state for each function.
const std = @import("std");

const Context = @import("Context.zig");
const Plan = @import("../planner.zig").Plan;
const catalog = @import("../catalog.zig");
const common = @import("common");
const oom = common.oom;
const Executor = @import("Executor.zig");
const scalar = @import("scalar.zig");
const Session = @import("../Session.zig");

/// Initialize the SRF DataNode
pub fn init(plan: *Plan.DataNode, cxt: *Context) !void {
    std.debug.assert(plan.action == .func);
    const inputs = cxt.alloc.alloc(common.Value, plan.action.func.inputs.len) catch oom();
    defer cxt.alloc.free(inputs);

    for (plan.action.func.inputs, inputs) |*i, *o| {
        std.debug.assert(i.action == .value);
        o.* = i.action.value;
    }

    plan.state = try catalog.functions.initSetReturningFunction(
        plan.action.func.func,
        plan.descr,
        inputs,
        cxt.alloc,
    );
}

/// Initialize the SRF DataNode
pub fn deinit(plan: *Plan.DataNode, cxt: *Context) void {
    std.debug.assert(plan.action == .func);

    catalog.functions.deinitSetReturningFunction(
        plan.action.func.func,
        plan.state.?,
        cxt.alloc,
    );
}

/// Rewind SRF DataNode to start from the first tuple again
pub fn rewind(plan: *Plan.DataNode) !void {
    std.debug.assert(plan.action == .func);
    // Simply recurse to child
    catalog.functions.rewindSetReturningFunction(
        plan.action.func.func,
        plan.state.?,
    );
}

/// Fetch one tuple from SRF DataNode
pub fn next(plan: *Plan.DataNode, cxt: *Context) !?common.MemTuple {
    std.debug.assert(plan.action == .func);
    // Get one tuple from child
    return try catalog.functions.execSetReturningFunction(
        plan.action.func.func,
        plan.state.?,
        cxt.alloc,
    );
}
