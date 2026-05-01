//! This is the executor for scalar nodes, corresponding to expressions

const std = @import("std");

const Context = @import("Context.zig");
const Plan = @import("../planner.zig").Plan;
const data = @import("../data.zig");
const oom = @import("../utils.zig").oom;

/// Evaluate a scalar node in the context of some tuple
pub fn eval(scalar: *const Plan.ScalarNode, tuple: data.MemTuple) data.Value {
    switch (scalar.action) {
        .column => |i| return tuple.getValue(i), // Get column from tuple
        .value => |v| return v, // Constant value
    }
}
