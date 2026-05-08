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
            return switch (u.op) {
                .neg => if (x == .null) .null else .{ .int = -x.int },
                .not => if (x == .null) .null else .{ .boolean = !x.boolean },
                .null => .{ .boolean = x == .null },
                .not_null => .{ .boolean = x != .null },
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
                        .@"and" => lhs.boolean and rhs.boolean,
                        .@"or" => lhs.boolean or rhs.boolean,
                        else => unreachable,
                    };
                    return .{ .boolean = v };
                },
                .eq, .ne => {
                    const v = switch (lhs) {
                        .null => unreachable,
                        .boolean => lhs.boolean == rhs.boolean,
                        .int => lhs.int == rhs.int,
                        .text => std.mem.eql(u8, lhs.text.text(), rhs.text.text()),
                    };
                    return .{ .boolean = if (b.op == .eq) v else !v };
                },
                .lt, .gt, .le, .ge => {
                    const v = switch (b.op) {
                        .lt => lhs.int < rhs.int,
                        .gt => lhs.int > rhs.int,
                        .le => lhs.int <= rhs.int,
                        .ge => lhs.int >= rhs.int,
                        else => unreachable,
                    };
                    return .{ .boolean = v };
                },
            }
        },
    }
}
