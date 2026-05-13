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
        .select => return p.planSelect(stmt.select),
        .@"union" => return p.planUnion(stmt.@"union"),
        .delete => return p.planDelete(stmt.delete),
        .insert_values => return p.planInsertValues(stmt.insert_values),
        .update => return p.planUpdate(stmt.update),
        .truncate => return p.planTruncate(stmt.truncate),
        .begin => return p.make(@as(Plan.Statement, .begin)),
        .commit => return p.make(@as(Plan.Statement, .commit)),
        .rollback => return p.make(@as(Plan.Statement, .rollback)),
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

/// Plan DROP TABLE statement
fn planDropTable(p: *Planner, stmt: ast.Statement.DropTable) *Plan.Statement {
    const table = p.findTable(stmt.name);
    return p.make(Plan.Statement{ .drop_table = .{
        .table = table.rel_id,
        .toast_table = table.rel_toast_id,
    } });
}

/// Plan TRUNCATE statement
fn planTruncate(p: *Planner, stmt: ast.Statement.Truncate) *Plan.Statement {
    const table = p.findTable(stmt.name);
    return p.make(Plan.Statement{ .truncate = .{
        .table = table.rel_id,
        .toast_table = table.rel_toast_id,
    } });
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
            if (att.t == .serial) {
                scalar.* = .{
                    .dbtype = att.t,
                    .action = .{ .next_serial = table.rel_id },
                };
            }
        }
    }

    // Plan the VALUES data source
    var root = p.planValues(stmt.values);
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
        .root = root,
    } });
}

/// Plan SELECT statement
fn planSelect(p: *Planner, stmt: ast.Statement.Select) *Plan.Statement {
    // Plan the data source for input
    const source = stmt.source;
    const input_node = p.planDataSource(source);

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
    // Add a filter if we have a WHERE clause
    if (stmt.where) |condition| {
        const expr = p.make(p.planExpression(condition.*));

        root = p.make(Plan.DataNode{
            .descr = root.descr,
            .action = .{ .filter = .{
                .input = root,
                .condition = expr,
            } },
        });
    }

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
    // Plan the data source for input
    const full_descr = p.cat.descr.getPtr(stmt.name.id.?).?;
    const input_node = p.planDataSource(&.{
        .u = .{ .table = .{ .name = stmt.name } },
        .t = full_descr,
    });

    // This is the input data
    var root = input_node;
    // Add a filter if we have a WHERE clause
    if (stmt.where) |condition| {
        const expr = p.make(p.planExpression(condition.*));

        root = p.make(Plan.DataNode{
            .descr = root.descr,
            .action = .{ .filter = .{
                .input = root,
                .condition = expr,
            } },
        });
    }

    // Make the statement node
    return p.make(Plan.Statement{ .delete = .{
        .table = stmt.name.id.?,
        .root = root,
    } });
}

/// Plan UPDATE statement
fn planUpdate(p: *Planner, stmt: ast.Statement.Update) *Plan.Statement {
    // Plan the data source for input
    const table = p.findTable(stmt.name);
    const full_descr = p.cat.descr.getPtr(stmt.name.id.?).?;
    const input_node = p.planDataSource(&.{
        .u = .{ .table = .{ .name = stmt.name } },
        .t = full_descr,
    });

    // This is the input data
    var root = input_node;
    // Add a filter if we have a WHERE clause
    if (stmt.where) |condition| {
        const expr = p.make(p.planExpression(condition.*));

        root = p.make(Plan.DataNode{
            .descr = root.descr,
            .action = .{ .filter = .{
                .input = root,
                .condition = expr,
            } },
        });
    }

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
        .root = root,
        .cols = cols.toOwnedSlice(p.alloc) catch oom(),
        .vals = vals.toOwnedSlice(p.alloc) catch oom(),
    } });
}

/// Plan a data source node.
/// This is currently very simple because almost nothing is supported.
fn planDataSource(p: *Planner, source: *const ast.DataSource) *Plan.DataNode {
    switch (source.u) {
        .table => return p.planFullScan(source),
        .join => return p.planNestedLoop(source),
        .values => return p.planValues(source),
        .func => return p.planSRF(source),
        .err => unreachable,
    }
}

/// Plan a full scan node for a table.
fn planFullScan(p: *Planner, ds: *const ast.DataSource) *Plan.DataNode {
    return p.make(Plan.DataNode{
        .descr = ds.t.?,
        .action = .{ .full_scan = .{
            .table = ds.u.table.name.id.?,
        } },
    });
}

/// Plan a nested loop join.
fn planNestedLoop(p: *Planner, ds: *const ast.DataSource) *Plan.DataNode {
    // Plan children data sources
    const lhs = p.planDataSource(ds.u.join.lhs);
    const rhs = p.planDataSource(ds.u.join.rhs);
    // Plan the join condition
    const cond = if (ds.u.join.cond) |c|
        p.make(p.planExpression(c.*))
    else
        null;

    return switch (ds.u.join.kind) {
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
}

/// Plan a data source node for VALUES list
fn planValues(
    p: *Planner,
    ds: *const ast.DataSource,
) *Plan.DataNode {
    // The list of tuples in the VALUES
    var values_data =
        std.ArrayList(common.MemTuple).initCapacity(p.alloc, ds.u.values.data.len) catch oom();
    // Go through all the rows in the query
    for (ds.u.values.data) |row| {
        // Build the tuple
        var b = common.MemTuple.Builder.init(p.alloc, ds.t.?);
        for (row) |expr| {
            b.pushValue(expr.u.value);
        }
        values_data.appendAssumeCapacity(b.finalize());
    }

    // Build the data source node
    return p.make(Plan.DataNode{
        .descr = ds.t.?,
        .action = .{ .values = .{
            .data = values_data.toOwnedSlice(p.alloc) catch oom(),
        } },
    });
}

/// Plan a data source node for a set returning function
fn planSRF(
    p: *Planner,
    ds: *const ast.DataSource,
) *Plan.DataNode {
    // Plan the sub-expressions
    const children = p.alloc.alloc(Plan.ScalarNode, ds.u.func.inputs.len) catch oom();
    for (ds.u.func.inputs, children) |i, *o|
        o.* = p.planExpression(i);

    // Build the data source node
    return p.make(Plan.DataNode{
        .descr = ds.t.?,
        .action = .{ .func = .{
            .func = ds.u.func.func,
            .inputs = children,
        } },
    });
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
