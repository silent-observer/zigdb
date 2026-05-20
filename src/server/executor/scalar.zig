//! This is the executor for scalar nodes, corresponding to expressions

const std = @import("std");

const Context = @import("Context.zig");
const Session = @import("../Session.zig");
const Plan = @import("../planner.zig").Plan;
const common = @import("common");
const oom = common.oom;
const heap = @import("../heap.zig");
const toaster = @import("../toaster.zig");
const catalog = @import("../catalog.zig");

/// Evaluate a scalar node in the context of some tuple
pub fn eval(scalar: *const Plan.ScalarNode, tuple: common.MemTuple, cxt: *Context) !common.Value {
    switch (scalar.action) {
        .column => |i| {
            const v = tuple.values[i];
            switch (v) {
                // Text values might have been toasted, we should retrieve their raw representation
                .text => |t| return .{
                    .text = try toaster.retrieve(t, cxt.alloc, cxt.snapshot),
                },
                else => return v,
            }
        }, // Get column from tuple
        .value => |v| return v, // Constant value
        .next_serial => |t| {
            const s = Session.get();
            // Assume we already have the correct lock for this table
            const table = heap.Table.init(
                s.shared.storage_cache,
                .{ .db = s.db_id, .table = t },
            );
            return .{ .int = @intCast(try table.getNextSerial()) };
        },
        .unary => |u| {
            const x = try eval(u.child, tuple, cxt);
            return switch (u.op) {
                .neg => if (x == .null) .null else .{ .int = -x.int },
                .not => if (x == .null) .null else .{ .boolean = !x.boolean },
                .null => .{ .boolean = x == .null },
                .not_null => .{ .boolean = x != .null },
            };
        },
        .binary => |b| {
            const lhs = try eval(b.left, tuple, cxt);
            const rhs = try eval(b.right, tuple, cxt);
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
                    const v = common.Value.eql(lhs, rhs, scalar.dbtype);
                    return .{ .boolean = if (b.op == .eq) v else !v };
                },
                .lt, .gt, .le, .ge => {
                    const o = common.Value.order(lhs, rhs, scalar.dbtype);
                    const v = switch (b.op) {
                        .lt => o.compare(.lt),
                        .gt => o.compare(.gt),
                        .le => o.compare(.lte),
                        .ge => o.compare(.gte),
                        else => unreachable,
                    };
                    return .{ .boolean = v };
                },
            }
        },
        .func => |f| {
            const values = cxt.alloc.alloc(common.Value, f.inputs.len) catch oom();
            defer cxt.alloc.free(values);
            for (f.inputs, values) |*i, *o|
                o.* = try eval(i, tuple, cxt);
            return try catalog.functions.evalScalarFunction(f.func, values, cxt.alloc);
        },
    }
}
