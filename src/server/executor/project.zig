//! This is the executor for Project DataNode
//! This performs a projection, evaluating a list of scalar expressions
//! for every tuple that passes through it.
//!
//! This executor has no special internal state.
const std = @import("std");

const Context = @import("Context.zig");
const Plan = @import("../planner.zig").Plan;
const common = @import("common");
const oom = common.oom;
const Executor = @import("Executor.zig");
const scalar = @import("scalar.zig");
const Session = @import("../Session.zig");

/// Initialize the Project DataNode
pub fn init(plan: *Plan.DataNode, cxt: *Context) !void {
    std.debug.assert(plan.action == .project);
    // Simply recurse to child
    try Executor.initDataNode(plan.action.project.input, cxt);
}

/// Initialize the Project DataNode
pub fn deinit(plan: *Plan.DataNode, cxt: *Context) void {
    std.debug.assert(plan.action == .project);
    // Simply recurse to child
    Executor.deinitDataNode(plan.action.project.input, cxt);
}

/// Rewind Project DataNode to start from the first tuple again
pub fn rewind(plan: *Plan.DataNode) !void {
    std.debug.assert(plan.action == .project);
    // Simply recurse to child
    try Executor.rewindDataNode(plan.action.project.input);
}

/// Fetch one tuple from Project DataNode
pub fn next(plan: *Plan.DataNode, cxt: *Context) !?common.MemTuple {
    const s = Session.get();
    std.debug.assert(plan.action == .project);
    // Get one tuple from child
    const input = try Executor.execDataNode(plan.action.project.input, cxt);
    // If the child is done, we are done too
    if (input == null) return null;

    // Build our new tuple
    var b = common.MemTuple.Builder.init(cxt.alloc, plan.descr);
    if (plan.action.project.exprs.len == 0) {
        // Special case: simply copy data from input
        for (0..input.?.len()) |i| {
            b.pushValue(input.?.getValue(i));
        }
    } else {
        // Go through our expressions
        for (plan.action.project.exprs) |expr| {
            // Evaluate each one and add the result to the output tuple
            const v = scalar.eval(&expr, input.?);
            b.pushValue(v);
        }
    }
    // Add extended fields if needed
    if (plan.descr.has_extended) {
        std.debug.assert(s.current_tid == .real);
        b.addExtended(.{
            .xmin = s.current_tid.real,
            .xmax = .invalid,
            .pos = .none,
        });
    }
    return b.finalize();
}
