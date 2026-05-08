//! This is the executor for scalar nodes, corresponding to expressions

const std = @import("std");

const Context = @import("Context.zig");
const Plan = @import("../planner.zig").Plan;
const common = @import("common");
const oom = common.oom;

/// Evaluate a scalar node in the context of some tuple
pub fn eval(scalar: *const Plan.ScalarNode, tuple: common.MemTuple) common.Value {
    switch (scalar.action) {
        .column => |i| return tuple.getValue(i), // Get column from tuple
        .value => |v| return v, // Constant value
        .unary => |u| {
            const x = eval(u.child, tuple);
            if (x == .null)
                return .null;
            return switch (u.op) {
                .neg => .{ .int = -x.int },
                .not => .{ .bool = !x.bool },
            };
        },
        .binary => |b| {
            const lhs = eval(b.left, tuple);
            const rhs = eval(b.right, tuple);
            if (lhs == .null or rhs == .null)
                return .null;
            switch (b.op) {
                .add, .sub, .mul, .div => {
                    const v = switch (b.op) {
                        .add => lhs.int + rhs.int,
                        .sub => lhs.int - rhs.int,
                        .mul => lhs.int * rhs.int,
                        .div => @divTrunc(lhs.int, rhs.int),
                        else => unreachable,
                    };
                    return .{ .int = v };
                },
                .@"and", .@"or" => {
                    const v = switch (b.op) {
                        .@"and" => lhs.bool and rhs.bool,
                        .@"or" => lhs.bool or rhs.bool,
                        else => unreachable,
                    };
                    return .{ .bool = v };
                },
                .eq, .ne => {
                    const v = switch (lhs) {
                        .null => unreachable,
                        .bool => lhs.bool == rhs.bool,
                        .int => lhs.int == rhs.int,
                        .text => std.mem.eql(u8, lhs.text, rhs.text),
                    };
                    return .{ .bool = v };
                },
                .lt, .gt, .le, .ge => {
                    const v = switch (b.op) {
                        .lt => lhs.int < rhs.int,
                        .gt => lhs.int > rhs.int,
                        .le => lhs.int <= rhs.int,
                        .ge => lhs.int >= rhs.int,
                        else => unreachable,
                    };
                    return .{ .bool = v };
                },
            }
        },
    }
}
