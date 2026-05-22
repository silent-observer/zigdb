//! This is a planner, the object that forms a plan from a statement from its AST.

const std = @import("std");

const Plan = @import("Plan.zig");
const ast = @import("../sql/ast.zig");
const common = @import("common");
const ids = common.ids;
const catalog = @import("../catalog.zig");
const oom = common.oom;

const Planner = @This();

/// Allocator for the plan
alloc: std.mem.Allocator,
/// Catalog cache to read metadata
cat: *catalog.Cache,
/// Planning errors
errors: std.ArrayList([]const u8),

pub const Error = error{
    NotSupported,
};

/// Initialize the planner
pub fn init(alloc: std.mem.Allocator, cat: *catalog.Cache) Planner {
    return Planner{
        .alloc = alloc,
        .cat = cat,
        .errors = .empty,
    };
}

/// Allocate memory for a value
pub fn make(p: *Planner, val: anytype) *@TypeOf(val) {
    const ptr = p.alloc.create(@TypeOf(val)) catch oom();
    ptr.* = val;
    return ptr;
}

/// Plan a statement
pub fn plan(p: *Planner, stmt: ast.Statement) *Plan.Statement {
    switch (stmt) {
        .create_table => return p.planCreateTable(stmt.create_table),
        .drop_table => return p.planDropTable(stmt.drop_table),
        .create_index => return p.planCreateIndex(stmt.create_index),
        .drop_index => return p.planDropIndex(stmt.drop_index),
        .select => return p.planSelect(stmt.select),
        .@"union" => return p.planUnion(stmt.@"union"),
        .delete => return p.planDelete(stmt.delete),
        .insert_values => return p.planInsertValues(stmt.insert_values),
        .update => return p.planUpdate(stmt.update),
        .truncate => return p.planTruncate(stmt.truncate),
        .begin => return p.make(@as(Plan.Statement, .begin)),
        .commit => return p.make(@as(Plan.Statement, .commit)),
        .rollback => return p.make(@as(Plan.Statement, .rollback)),
        .show_table => return p.planShowTable(stmt.show_table),
        .show_tables => return p.make(@as(Plan.Statement, .show_tables)),
        .err => unreachable,
    }
}

/// Plan CREATE TABLE statement
fn planCreateTable(p: *Planner, stmt: ast.Statement.CreateTable) *Plan.Statement {
    // Build the TupleDescriptor for the new table
    const descr = p.make(common.TupleDescriptor.empty_extended);
    descr.attrs.ensureUnusedCapacity(
        p.alloc,
        stmt.columns.len,
    ) catch oom();
    for (stmt.columns) |c| {
        descr.attrs.appendAssumeCapacity(.{
            .name = c.name.text,
            .t = c.col_type,
            .table_name = stmt.name.text,
        });
    }

    // Convert name to lowercase
    const lower_name = std.ascii.allocLowerString(
        p.alloc,
        stmt.name.text,
    ) catch oom();

    // Make the statement node.
    return p.make(Plan.Statement{ .create_table = .{
        .name = lower_name,
        .descr = descr,
    } });
}

/// Adds a formatted error to the error list.
fn addError(p: *Planner, comptime fmt: []const u8, args: anytype) void {
    const str = std.fmt.allocPrint(
        p.alloc,
        fmt,
        args,
    ) catch oom();
    p.errors.append(p.alloc, str) catch oom();
}

/// Finds a table by its id
fn findTable(p: *Planner, name: ast.Name) catalog.Entry(.zdb_rels) {
    // Scan through the catalog
    var scanner = p.cat.catalog.zdb_rels.scan(
        &.{.rel_id},
        &.{name.id.?},
    );
    return scanner.next().?;
}

fn findIndexesToUpdate(p: *Planner, table: ast.Name) []Plan.IndexInfo {
    var result: std.ArrayList(Plan.IndexInfo) = .empty;
    // Scan through the catalog
    var scanner = p.cat.catalog.zdb_indexes.scan(
        &.{.index_rel_id},
        &.{table.id.?},
    );
    while (scanner.next()) |index| {
        const cols = p.alloc.alloc(u16, index.index_cols.len) catch oom();
        for (index.index_cols, cols) |v, *c|
            c.* = v.to(u16) catch unreachable;

        result.append(p.alloc, .{
            .index = index.index_id,
            .descr = p.cat.index_descr.getPtr(index.index_id).?,
            .cols = cols,
        }) catch oom();
    }
    return result.toOwnedSlice(p.alloc) catch oom();
}

/// Plan DROP TABLE statement
fn planDropTable(p: *Planner, stmt: ast.Statement.DropTable) *Plan.Statement {
    const table = p.findTable(stmt.name);
    return p.make(Plan.Statement{ .drop_table = .{
        .table = table.rel_id,
        .toast_table = table.rel_toast_id,
        .indexes = p.findIndexesToUpdate(stmt.name),
    } });
}

/// Plan CREATE INDEX statement
fn planCreateIndex(p: *Planner, stmt: ast.Statement.CreateIndex) *Plan.Statement {
    // Build the column list for the new index
    const columns = p.alloc.alloc(Plan.ColumnId, stmt.columns.len) catch oom();
    for (stmt.columns, columns) |n, *id|
        id.* = @intCast(n.id.?);

    // Convert name to lowercase
    const lower_name = std.ascii.allocLowerString(
        p.alloc,
        stmt.name.text,
    ) catch oom();

    // Make the statement node.
    return p.make(Plan.Statement{ .create_index = .{
        .name = lower_name,
        .table = stmt.table.id.?,
        .cols = columns,
    } });
}

/// Plan DROP INDEX statement
fn planDropIndex(p: *Planner, stmt: ast.Statement.DropIndex) *Plan.Statement {
    return p.make(Plan.Statement{ .drop_index = .{
        .index = stmt.name.id.?,
    } });
}

/// Plan TRUNCATE statement
fn planTruncate(p: *Planner, stmt: ast.Statement.Truncate) *Plan.Statement {
    const table = p.findTable(stmt.name);
    return p.make(Plan.Statement{ .truncate = .{
        .table = table.rel_id,
        .toast_table = table.rel_toast_id,
        .indexes = p.findIndexesToUpdate(stmt.name),
    } });
}

/// Plan SHOW TABLE statement
fn planShowTable(p: *Planner, name: ast.Name) *Plan.Statement {
    const table = p.findTable(name);
    return p.make(Plan.Statement{ .show_table = table.rel_id });
}

/// Plan INSERT VALUES statement
fn planInsertValues(p: *Planner, stmt: ast.Statement.InsertValues) *Plan.Statement {
    // Find the target table
    const table = p.findTable(stmt.name);
    const full_descr = p.cat.descr.getPtr(table.rel_id).?;
    // List of expressions for projection
    var scalar_node =
        std.ArrayList(Plan.ScalarNode).initCapacity(p.alloc, full_descr.len()) catch oom();
    var column_given =
        std.DynamicBitSetUnmanaged.initEmpty(p.alloc, full_descr.len()) catch oom();

    // This is the descriptor of what we get as input data
    if (stmt.columns.len > 0) {
        _ = scalar_node.addManyAsSliceAssumeCapacity(full_descr.len());

        // Go through the columns in the statement
        for (stmt.columns, 0..) |col_name, i| {
            // col_id is the index in the physical table, i is the index in the query
            const col_id = col_name.id.?;
            // Build an expression for each physical column
            scalar_node.items[col_id] = .{
                .action = .{ .column = @intCast(i) },
                .dbtype = full_descr.attrs.items[col_id].t,
            };
            column_given.set(col_id);
        }

        // Fill in missing columns with default values
        for (
            scalar_node.items,
            full_descr.attrs.items,
            0..,
        ) |*scalar, att, i| {
            if (column_given.isSet(i)) continue;
            if (att.t == .base and att.t.base == .serial) {
                scalar.* = .{
                    .dbtype = att.t,
                    .action = .{ .next_serial = table.rel_id },
                };
            }
        }
    }

    // Plan the VALUES data source
    var root = p.planValues(.{ .source = stmt.values });
    // We always need a projection node to add extended fields
    {
        // Add the projection node on top of VALUES, if needed
        root = p.make(Plan.DataNode{
            .descr = full_descr,
            .action = .{ .project = .{
                .input = root,
                .exprs = scalar_node.toOwnedSlice(p.alloc) catch oom(),
                .op = if (scalar_node.items.len > 0) .evaluate else .copy,
            } },
        });
    }

    // Finally make the statement node
    return p.make(Plan.Statement{ .insert = .{
        .table = table.rel_id,
        .toast_table = table.rel_toast_id,
        .indexes = p.findIndexesToUpdate(stmt.name),
        .root = root,
    } });
}

const AndExpression = struct {
    terms: std.ArrayList(*ast.Expression) = .empty,

    fn finalize(self: AndExpression, alloc: std.mem.Allocator) ?*ast.Expression {
        if (self.terms.items.len == 0) return null;

        var lhs = self.terms.items[0];
        for (self.terms.items[1..]) |rhs| {
            const new = alloc.create(ast.Expression) catch oom();
            new.* = .{
                .t = .b(.boolean),
                .u = .{ .binary = .{
                    .left = lhs,
                    .right = rhs,
                    .op = .@"and",
                } },
            };
            lhs = new;
        }
        return lhs;
    }
};

const StructuredCondition = struct {
    var_var_equality: []VarVarEquality,
    var_const_equality: []VarConstEquality,
    var_const_inequality: []VarConstInequality,
    extra: ?*ast.Expression,
    always_true: bool,
    always_false: bool,

    const empty = StructuredCondition{
        .var_var_equality = &.{},
        .var_const_equality = &.{},
        .var_const_inequality = &.{},
        .extra = null,
        .always_true = false,
        .always_false = false,
    };

    const empty_true = StructuredCondition{
        .var_var_equality = &.{},
        .var_const_equality = &.{},
        .var_const_inequality = &.{},
        .extra = null,
        .always_true = true,
        .always_false = false,
    };

    const empty_false = StructuredCondition{
        .var_var_equality = &.{},
        .var_const_equality = &.{},
        .var_const_inequality = &.{},
        .extra = null,
        .always_true = false,
        .always_false = true,
    };

    const VarVarEquality = struct {
        original: *ast.Expression,
        lhs: ast.Expression.Variable,
        rhs: ast.Expression.Variable,
    };

    const VarConstEquality = struct {
        original: *ast.Expression,
        expr: ast.Expression.Variable,
        val: common.Value,
    };

    const VarConstInequality = struct {
        original: *ast.Expression,
        expr: ast.Expression.Variable,
        val: common.Value,
        op: Op,
        const Op = enum { lt, le, gt, ge };
    };

    const Builder = struct {
        alloc: std.mem.Allocator,
        var_var_equality: std.ArrayList(VarVarEquality),
        var_const_equality: std.ArrayList(VarConstEquality),
        var_const_inequality: std.ArrayList(VarConstInequality),
        extra: AndExpression,
        always_true: bool,
        always_false: bool,

        fn init(alloc: std.mem.Allocator) Builder {
            return .{
                .alloc = alloc,
                .var_var_equality = .empty,
                .var_const_equality = .empty,
                .var_const_inequality = .empty,
                .extra = .{},
                .always_true = false,
                .always_false = false,
            };
        }

        fn toVarVarEq(cond: *ast.Expression) ?VarVarEquality {
            switch (cond.u) {
                .binary => |binary| switch (binary.op) {
                    .eq => {
                        if (binary.left.u == .variable and binary.right.u == .variable)
                            return .{
                                .original = cond,
                                .lhs = binary.left.u.variable,
                                .rhs = binary.right.u.variable,
                            }
                        else
                            return null;
                    },
                    else => return null,
                },
                else => return null,
            }
        }

        fn toVarConstEq(cond: *ast.Expression) ?VarConstEquality {
            switch (cond.u) {
                .variable => |v| return .{
                    .original = cond,
                    .expr = v,
                    .val = .{ .boolean = true },
                },
                .unary => |u| switch (u.op) {
                    .not => {
                        if (u.expr.u == .variable)
                            return .{
                                .original = cond,
                                .expr = u.expr.u.variable,
                                .val = .{ .boolean = false },
                            }
                        else
                            return null;
                    },
                    .null => {
                        if (u.expr.u == .variable)
                            return .{
                                .original = cond,
                                .expr = u.expr.u.variable,
                                .val = .null,
                            }
                        else
                            return null;
                    },
                    else => return null,
                },
                .binary => |binary| switch (binary.op) {
                    .eq => {
                        if (binary.left.u == .variable and binary.right.u == .value)
                            return .{
                                .original = cond,
                                .expr = binary.left.u.variable,
                                .val = binary.right.u.value,
                            }
                        else if (binary.right.u == .variable and binary.left.u == .value)
                            return .{
                                .original = cond,
                                .expr = binary.right.u.variable,
                                .val = binary.left.u.value,
                            }
                        else
                            return null;
                    },
                    else => return null,
                },
                else => return null,
            }
        }

        fn toVarConstIneq(cond: *ast.Expression) ?VarConstInequality {
            switch (cond.u) {
                .unary => |u| switch (u.op) {
                    .not_null => {
                        if (u.expr.u == .variable)
                            return .{
                                .original = cond,
                                .expr = u.expr.u.variable,
                                .val = .null,
                                .op = .lt,
                            }
                        else
                            return null;
                    },
                    else => return null,
                },
                .binary => |binary| switch (binary.op) {
                    .lt, .gt, .le, .ge => {
                        if (binary.left.u == .variable and binary.right.u == .value)
                            return .{
                                .original = cond,
                                .expr = binary.left.u.variable,
                                .val = binary.right.u.value,
                                .op = switch (binary.op) {
                                    .lt => .lt,
                                    .le => .le,
                                    .gt => .gt,
                                    .ge => .ge,
                                    else => unreachable,
                                },
                            }
                        else if (binary.right.u == .variable and binary.left.u == .value)
                            return .{
                                .original = cond,
                                .expr = binary.right.u.variable,
                                .val = binary.left.u.value,
                                .op = switch (binary.op) {
                                    .lt => .gt,
                                    .le => .ge,
                                    .gt => .lt,
                                    .ge => .le,
                                    else => unreachable,
                                },
                            }
                        else
                            return null;
                    },
                    else => return null,
                },
                else => return null,
            }
        }

        fn addCond(b: *Builder, cond: *ast.Expression) void {
            if (cond.u == .binary and cond.u.binary.op == .@"and") {
                b.addCond(cond.u.binary.left);
                b.addCond(cond.u.binary.right);
                return;
            }

            if (cond.u == .value) switch (cond.u.value) {
                .null => {
                    b.always_false = true;
                    return;
                },
                .boolean => |boolean| {
                    if (boolean)
                        b.always_true = true
                    else
                        b.always_false = true;
                    return;
                },
                else => unreachable,
            };

            if (toVarVarEq(cond)) |vve|
                b.var_var_equality.append(b.alloc, vve) catch oom()
            else if (toVarConstEq(cond)) |vce|
                b.var_const_equality.append(b.alloc, vce) catch oom()
            else if (toVarConstIneq(cond)) |vcie|
                b.var_const_inequality.append(b.alloc, vcie) catch oom()
            else
                b.extra.terms.append(b.alloc, cond) catch oom();
        }

        fn finalize(b: *Builder) StructuredCondition {
            if (b.always_false)
                return .empty_false
            else if (b.always_true)
                return .empty_true;

            return .{
                .extra = b.extra.finalize(b.alloc),
                .var_var_equality = b.var_var_equality.toOwnedSlice(b.alloc) catch oom(),
                .var_const_equality = b.var_const_equality.toOwnedSlice(b.alloc) catch oom(),
                .var_const_inequality = b.var_const_inequality.toOwnedSlice(b.alloc) catch oom(),
                .always_false = false,
                .always_true = false,
            };
        }
    };

    fn build(cond: *ast.Expression, alloc: std.mem.Allocator) StructuredCondition {
        var b = Builder.init(alloc);
        b.addCond(cond);
        return b.finalize();
    }
};

const DataSourceRequest = struct {
    source: *const ast.DataSource,
    filter: StructuredCondition = .empty_true,
};

fn addFilter(p: *Planner, node: *Plan.DataNode, cond: *ast.Expression) *Plan.DataNode {
    return p.make(Plan.DataNode{
        .descr = node.descr,
        .action = .{ .filter = .{
            .input = node,
            .condition = p.make(p.planExpression(cond.*)),
        } },
    });
}

/// Plan SELECT statement
fn planSelect(p: *Planner, stmt: ast.Statement.Select) *Plan.Statement {
    // Try to structure the condition
    const cond: StructuredCondition = if (stmt.where) |where|
        .build(where, p.alloc)
    else
        .empty_true;

    // Plan the data source for input
    const source = stmt.source;
    const input_node = p.planDataSource(.{
        .source = source,
        .filter = cond,
    });

    // List of scalar nodes for expressions
    var scalar_nodes =
        std.ArrayList(Plan.ScalarNode).initCapacity(p.alloc, stmt.columns.len) catch oom();
    // Go through output columns in the query
    for (stmt.columns) |c| {
        // Build a scalar node for each expression
        switch (c) {
            .normal => |n| {
                const node = p.planExpression(n.expr.*);
                scalar_nodes.appendAssumeCapacity(node);
            },
            .star => {
                scalar_nodes.ensureTotalCapacity(
                    p.alloc,
                    scalar_nodes.capacity + input_node.descr.len() - 1,
                ) catch oom();

                for (input_node.descr.attrs.items, 0..) |att, i| {
                    scalar_nodes.appendAssumeCapacity(.{
                        .action = .{ .column = @intCast(i) },
                        .dbtype = att.t,
                    });
                }
            },
        }
    }

    // This is the input data
    var root = input_node;

    // SELECT basically always needs a projection
    {
        // Make the projection node
        root = p.make(Plan.DataNode{
            .descr = stmt.t.?,
            .action = .{ .project = .{
                .input = root,
                .exprs = scalar_nodes.toOwnedSlice(p.alloc) catch oom(),
                .op = .evaluate,
            } },
        });
    }

    // Make the statement node
    return p.make(Plan.Statement{ .select = .{ .root = root } });
}

/// Plan UNION statement
fn planUnion(p: *Planner, stmt: ast.Statement.Union) *Plan.Statement {
    // Plan all children one by operation
    var sources = std.ArrayList(Plan.DataNode)
        .initCapacity(p.alloc, stmt.stmts.len) catch oom();
    for (stmt.stmts) |child| {
        const child_plan = p.plan(child);
        std.debug.assert(child_plan.* == .select);
        sources.appendAssumeCapacity(child_plan.select.root.*);

        // Clena up the data nodes we got
        p.alloc.destroy(child_plan.select.root);
        p.alloc.destroy(child_plan);
    }
    std.debug.assert(sources.items.len > 0);

    return p.make(Plan.Statement{ .select = .{
        .root = p.make(Plan.DataNode{
            .descr = sources.items[0].descr,
            .action = .{ .union_all = .{
                .inputs = sources.toOwnedSlice(p.alloc) catch oom(),
            } },
        }),
    } });
}

/// Plan DELETE statement
fn planDelete(p: *Planner, stmt: ast.Statement.Delete) *Plan.Statement {
    // Try to structure the condition
    const cond: StructuredCondition = if (stmt.where) |where|
        .build(where, p.alloc)
    else
        .empty_true;
    // Plan the data source for input
    const full_descr = p.cat.descr.getPtr(stmt.name.id.?).?;
    const input_node = p.planDataSource(.{
        .source = &.{
            .u = .{ .table = .{ .name = stmt.name } },
            .t = full_descr,
        },
        .filter = cond,
    });

    // Make the statement node
    return p.make(Plan.Statement{ .delete = .{
        .table = stmt.name.id.?,
        .root = input_node,
    } });
}

/// Plan UPDATE statement
fn planUpdate(p: *Planner, stmt: ast.Statement.Update) *Plan.Statement {
    // Try to structure the condition
    const cond: StructuredCondition = if (stmt.where) |where|
        .build(where, p.alloc)
    else
        .empty_true;
    // Plan the data source for input
    const table = p.findTable(stmt.name);
    const full_descr = p.cat.descr.getPtr(stmt.name.id.?).?;
    const input_node = p.planDataSource(.{
        .source = &.{
            .u = .{ .table = .{ .name = stmt.name } },
            .t = full_descr,
        },
        .filter = cond,
    });

    // Fill the SET data
    var cols = std.ArrayList(Plan.ColumnId)
        .initCapacity(p.alloc, stmt.clauses.len) catch oom();
    var vals = std.ArrayList(Plan.ScalarNode)
        .initCapacity(p.alloc, stmt.clauses.len) catch oom();

    for (stmt.clauses) |clause| {
        const val = p.planExpression(clause.expr.*);

        cols.appendAssumeCapacity(@intCast(clause.column.id.?));
        vals.appendAssumeCapacity(val);
    }

    // Make the statement node
    return p.make(Plan.Statement{ .update = .{
        .table = table.rel_id,
        .toast_table = table.rel_toast_id,
        .indexes = p.findIndexesToUpdate(stmt.name),
        .root = input_node,
        .cols = cols.toOwnedSlice(p.alloc) catch oom(),
        .vals = vals.toOwnedSlice(p.alloc) catch oom(),
    } });
}

/// Plan a data source node.
/// This is currently very simple because almost nothing is supported.
fn planDataSource(p: *Planner, req: DataSourceRequest) *Plan.DataNode {
    if (req.filter.always_false) {
        return p.make(Plan.DataNode{
            .descr = req.source.t.?,
            .action = .{ .values = .{
                .data = &.{},
            } },
        });
    }

    switch (req.source.u) {
        .table => return p.planTableScan(req),
        .join => return p.planNestedLoop(req),
        .values => return p.planValues(req),
        .func => return p.planSRF(req),
        .err => unreachable,
    }
}

fn addFullFilter(
    p: *Planner,
    node: *Plan.DataNode,
    filter: StructuredCondition,
) *Plan.DataNode {
    if (!filter.always_true) {
        // None of the conditions can be applied cleverly, just AND them all
        var and_cond: AndExpression = .{};
        for (filter.var_var_equality) |e|
            and_cond.terms.append(p.alloc, e.original) catch oom();
        for (filter.var_const_equality) |e|
            and_cond.terms.append(p.alloc, e.original) catch oom();
        for (filter.var_const_inequality) |e|
            and_cond.terms.append(p.alloc, e.original) catch oom();
        if (filter.extra) |e|
            and_cond.terms.append(p.alloc, e) catch oom();
        const cond = and_cond.finalize(p.alloc);

        if (cond) |c|
            return p.addFilter(node, c);
    }

    return node;
}

fn addIndexFilter(
    p: *Planner,
    node: *Plan.DataNode,
    filter: StructuredCondition,
    info: Plan.IndexInfo,
) *Plan.DataNode {
    if (!filter.always_true) {
        const index_scan = &node.action.index_scan;
        // Some of the conditions can't be used with an index, just AND them all
        var and_cond: AndExpression = .{};
        // All variable-variable conditions can't be used
        for (filter.var_var_equality) |e|
            and_cond.terms.append(p.alloc, e.original) catch oom();
        for (filter.var_const_equality) |e| {
            // Try find this in the bounds
            const min_len = @min(index_scan.lower.len, index_scan.upper.len);
            for (info.cols[0..min_len]) |attr_id| {
                if (e.expr.name.id.? == attr_id) break;
            } else and_cond.terms.append(p.alloc, e.original) catch oom();
        }
        for (filter.var_const_inequality) |e| {
            // Try find this in the bounds
            const max_len = @max(index_scan.lower.len, index_scan.upper.len);
            for (info.cols[0..max_len]) |attr_id| {
                if (e.expr.name.id.? == attr_id) break;
            } else and_cond.terms.append(p.alloc, e.original) catch oom();
        }
        if (filter.extra) |e|
            and_cond.terms.append(p.alloc, e) catch oom();
        const cond = and_cond.finalize(p.alloc);

        if (cond) |c|
            return p.addFilter(node, c);
    }

    return node;
}

fn rateIndex(req: DataSourceRequest, info: Plan.IndexInfo) usize {
    if (req.filter.always_true or req.filter.always_false)
        return 0;

    var score: usize = 0;
    outer: for (info.cols) |attr_i| {
        for (req.filter.var_const_equality) |vce| {
            if (vce.expr.name.id.? == attr_i) {
                // Found equality, we can still do more
                score += 1;
                continue :outer;
            }
        }

        var lower_bound = false;
        var upper_bound = false;
        for (req.filter.var_const_inequality) |vcie| {
            if (vcie.expr.name.id.? == attr_i) {
                switch (vcie.op) {
                    .gt, .ge => lower_bound = true,
                    .lt, .le => upper_bound = true,
                }
            }
        }
        if (lower_bound or upper_bound) {
            // Found inequality/range, we are done with this index
            score += 1;
            break :outer;
        }
    }
    return score;
}

fn constructIndexScan(
    p: *Planner,
    req: DataSourceRequest,
    index: Plan.IndexInfo,
) Plan.DataNode.Action.IndexScan {
    var lower: std.ArrayList(common.Value) = .empty;
    var upper: std.ArrayList(common.Value) = .empty;
    var lower_inclusive = true;
    var upper_inclusive = true;

    outer: for (index.cols) |attr_i| {
        for (req.filter.var_const_equality) |vce| {
            if (vce.expr.name.id.? == attr_i) {
                // Found equality, we can still do more
                lower.append(p.alloc, vce.val) catch oom();
                upper.append(p.alloc, vce.val) catch oom();
                continue :outer;
            }
        }

        var lower_bound = false;
        var upper_bound = false;
        for (req.filter.var_const_inequality) |vcie| {
            if (vcie.expr.name.id.? == attr_i) {
                switch (vcie.op) {
                    .ge, .gt => {
                        // Already have some bound
                        if (lower_bound) {
                            const prev = lower.getLast();
                            const o = vcie.val.order(prev, vcie.original.t.?);
                            if (o == .gt) {
                                lower.items[lower.items.len - 1] = vcie.val;
                                lower_inclusive = vcie.op == .ge;
                            } else if (o == .eq and lower_inclusive) {
                                lower_inclusive = vcie.op == .ge;
                            }
                        } else {
                            lower.append(p.alloc, vcie.val) catch oom();
                            lower_bound = true;
                            lower_inclusive = vcie.op == .ge;
                        }
                    },
                    .le, .lt => {
                        // Already have some bound
                        if (upper_bound) {
                            const prev = upper.getLast();
                            const o = vcie.val.order(prev, vcie.original.t.?);
                            if (o == .lt) {
                                upper.items[upper.items.len - 1] = vcie.val;
                                upper_inclusive = vcie.op == .le;
                            } else if (o == .eq and upper_inclusive) {
                                upper_inclusive = vcie.op == .le;
                            }
                        } else {
                            upper.append(p.alloc, vcie.val) catch oom();
                            upper_bound = true;
                            upper_inclusive = vcie.op == .le;
                        }
                    },
                }
            }
        }
        if (lower_bound or upper_bound)
            // Found inequality/range, we are done with this index
            break :outer;
    }

    return .{
        .table = req.source.u.table.name.id.?,
        .index = index.index,
        .index_descr = index.descr,
        .lower = lower.toOwnedSlice(p.alloc) catch oom(),
        .upper = upper.toOwnedSlice(p.alloc) catch oom(),
        .lower_inclusive = lower_inclusive,
        .upper_inclusive = upper_inclusive,
    };
}

/// Plan a table scan node for a table.
fn planTableScan(p: *Planner, req: DataSourceRequest) *Plan.DataNode {
    const ds = req.source;
    // Try to use index scan if we can
    const indexes = p.findIndexesToUpdate(ds.u.table.name);
    var best_index: ?Plan.IndexInfo = null;
    var best_score: usize = 0;
    for (indexes) |info| {
        const score = rateIndex(req, info);
        if (score > best_score) {
            best_index = info;
            best_score = score;
        }
    }

    if (best_index) |info| {
        const node = p.make(Plan.DataNode{
            .descr = ds.t.?,
            .action = .{
                .index_scan = p.constructIndexScan(req, info),
            },
        });

        return p.addIndexFilter(node, req.filter, info);
    }

    const node = p.make(Plan.DataNode{
        .descr = ds.t.?,
        .action = .{ .full_scan = .{
            .table = ds.u.table.name.id.?,
        } },
    });

    return p.addFullFilter(node, req.filter);
}

/// Plan a nested loop join.
fn planNestedLoop(p: *Planner, req: DataSourceRequest) *Plan.DataNode {
    const ds = req.source;
    // Plan children data sources
    const lhs = p.planDataSource(.{ .source = ds.u.join.lhs });
    const rhs = p.planDataSource(.{ .source = ds.u.join.rhs });
    // Plan the join condition
    const cond = if (ds.u.join.cond) |c|
        p.make(p.planExpression(c.*))
    else
        null;

    const node = switch (ds.u.join.kind) {
        .cross => p.make(Plan.DataNode{
            .descr = ds.t.?,
            .action = .{ .nested_loop = .{
                .lhs = lhs,
                .rhs = rhs,
                .cond = null,
                .cond_descr = ds.t.?,
                .cond_format = .left_right,
                .op = .cross,
                .output_format = .left_right,
            } },
        }),
        .inner => p.make(Plan.DataNode{
            .descr = ds.t.?,
            .action = .{ .nested_loop = .{
                .lhs = lhs,
                .rhs = rhs,
                .cond = cond,
                .cond_descr = ds.t.?,
                .cond_format = .left_right,
                .op = .inner,
                .output_format = .left_right,
            } },
        }),
        .left => p.make(Plan.DataNode{
            .descr = ds.t.?,
            .action = .{ .nested_loop = .{
                .lhs = lhs,
                .rhs = rhs,
                .cond = cond,
                .cond_descr = ds.t.?,
                .cond_format = .left_right,
                .op = .left,
                .output_format = .left_right,
            } },
        }),
        .right => p.make(Plan.DataNode{
            .descr = ds.t.?,
            .action = .{ .nested_loop = .{
                .lhs = rhs,
                .rhs = lhs,
                .cond = cond,
                .cond_descr = ds.t.?,
                .cond_format = .right_left,
                .op = .left,
                .output_format = .right_left,
            } },
        }),
        // Full Join uses a special form:
        //    select A.*, B.* from A full join B on COND
        // = (select A.*, B.* from A left join B on COND) union all
        //   (select NULL as A.*, B.* from B where not exists(select 1 from A where COND))
        .full => out: {
            const inputs = p.alloc.alloc(Plan.DataNode, 2) catch oom();
            inputs[0] = Plan.DataNode{
                .descr = ds.t.?,
                .action = .{ .nested_loop = .{
                    .lhs = lhs,
                    .rhs = rhs,
                    .cond = cond,
                    .cond_descr = ds.t.?,
                    .cond_format = .left_right,
                    .op = .left,
                    .output_format = .left_right,
                } },
            };
            const anti_semi_join = p.make(Plan.DataNode{
                .descr = rhs.descr,
                .action = .{ .nested_loop = .{
                    .lhs = rhs,
                    .rhs = lhs,
                    .cond = cond,
                    .cond_descr = ds.t.?,
                    .cond_format = .right_left,
                    .op = .anti_semi,
                    .output_format = .left_only,
                } },
            });
            inputs[1] = Plan.DataNode{
                .descr = ds.t.?,
                .action = .{ .project = .{
                    .input = anti_semi_join,
                    .exprs = &.{},
                    .op = .prepend_nulls,
                } },
            };
            break :out p.make(Plan.DataNode{
                .descr = ds.t.?,
                .action = .{ .union_all = .{
                    .inputs = inputs,
                } },
            });
        },
    };

    return p.addFullFilter(node, req.filter);
}

/// Plan a data source node for VALUES list
fn planValues(p: *Planner, req: DataSourceRequest) *Plan.DataNode {
    const ds = req.source;
    // The list of tuples in the VALUES
    var values_data =
        std.ArrayList(common.MemTuple).initCapacity(p.alloc, ds.u.values.data.len) catch oom();
    // Go through all the rows in the query
    for (ds.u.values.data) |row| {
        // Build the tuple
        const values = p.alloc.alloc(common.Value, row.len) catch oom();
        for (row, values) |expr, *v| {
            v.* = expr.u.value;
        }
        values_data.appendAssumeCapacity(.{
            .descr = ds.t.?,
            .ext = null,
            .values = values,
        });
    }

    // Build the data source node
    const node = p.make(Plan.DataNode{
        .descr = ds.t.?,
        .action = .{ .values = .{
            .data = values_data.toOwnedSlice(p.alloc) catch oom(),
        } },
    });
    return p.addFullFilter(node, req.filter);
}

/// Plan a data source node for a set returning function
fn planSRF(p: *Planner, req: DataSourceRequest) *Plan.DataNode {
    const ds = req.source;
    // Plan the sub-expressions
    const children = p.alloc.alloc(Plan.ScalarNode, ds.u.func.inputs.len) catch oom();
    for (ds.u.func.inputs, children) |i, *o|
        o.* = p.planExpression(i);

    // Build the data source node
    const node = p.make(Plan.DataNode{
        .descr = ds.t.?,
        .action = .{ .func = .{
            .func = ds.u.func.func,
            .inputs = children,
        } },
    });
    return p.addFullFilter(node, req.filter);
}

/// Plan the scalar node for an expression (in the context of some tuple descriptor).
fn planExpression(p: *Planner, expr: ast.Expression) Plan.ScalarNode {
    // Fast path for constant expressions
    if (expr.u == .value) {
        return Plan.ScalarNode{
            .action = .{ .value = expr.u.value },
            .dbtype = expr.t.?,
        };
    }

    switch (expr.u) {
        .variable => |v| { // Variable expression
            return Plan.ScalarNode{
                .action = .{ .column = @intCast(v.name.id.?) },
                .dbtype = expr.t.?,
            };
        },
        .unary => |u| {
            const child = p.make(p.planExpression(u.expr.*));
            return Plan.ScalarNode{
                .action = .{ .unary = .{
                    .op = u.op,
                    .child = child,
                } },
                .dbtype = expr.t.?,
            };
        },
        .binary => |b| {
            const left = p.make(p.planExpression(b.left.*));
            const right = p.make(p.planExpression(b.right.*));
            return Plan.ScalarNode{
                .action = .{ .binary = .{
                    .op = b.op,
                    .left = left,
                    .right = right,
                } },
                .dbtype = expr.t.?,
            };
        },
        .func => |f| {
            const children = p.alloc.alloc(Plan.ScalarNode, f.inputs.len) catch oom();
            for (f.inputs, children) |i, *o|
                o.* = p.planExpression(i);
            return Plan.ScalarNode{
                .action = .{ .func = .{
                    .func = f.func,
                    .inputs = children,
                } },
                .dbtype = expr.t.?,
            };
        },
        .value => unreachable, // This is supposed to be a constant
        .err => unreachable,
    }
}
