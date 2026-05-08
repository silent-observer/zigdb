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
    UnknownName,
    NotAConstant,
    TypeError,
    Other,
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
pub fn plan(p: *Planner, stmt: ast.Statement) Error!*Plan.Statement {
    switch (stmt) {
        .create_table => return p.planCreateTable(stmt.create_table),
        .drop_table => return p.planDropTable(stmt.drop_table),
        .select => return p.planSelect(stmt.select),
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
fn planCreateTable(p: *Planner, stmt: ast.Statement.CreateTable) Error!*Plan.Statement {
    // Build the TupleDescriptor for the new table
    const descr = p.make(common.TupleDescriptor.empty);
    descr.attrs.ensureUnusedCapacity(
        p.alloc,
        stmt.columns.len,
    ) catch oom();
    for (stmt.columns) |c| {
        descr.attrs.appendAssumeCapacity(.{
            .name = c.name,
            .t = c.col_type,
        });
    }

    // Convert name to lowercase
    const lower_name = std.ascii.allocLowerString(
        p.alloc,
        stmt.name,
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

/// Finds a table by its name
fn findTable(p: *Planner, name: []const u8) Error!ids.TableId {
    // Scan through the catalog
    var scanner = p.cat.catalog.zdb_rels.scanTextIgnoreCase(
        .rel_name,
        name,
        &.{},
        &.{},
    );
    const table = scanner.next();
    if (table) |t| {
        // If found, return it
        return t.rel_id;
    } else {
        // If not found, emit error
        p.addError("Unknown table \"{s}\"", .{name});
        return Error.UnknownName;
    }
}

/// Plan DROP TABLE statement
fn planDropTable(p: *Planner, stmt: ast.Statement.DropTable) Error!*Plan.Statement {
    return p.make(Plan.Statement{ .drop_table = .{
        .table = try p.findTable(stmt.name),
    } });
}

/// Plan TRUNCATE statement
fn planTruncate(p: *Planner, stmt: ast.Statement.Truncate) Error!*Plan.Statement {
    return p.make(Plan.Statement{ .truncate = .{
        .table = try p.findTable(stmt.name),
    } });
}

/// Plan INSERT VALUES statement
fn planInsertValues(p: *Planner, stmt: ast.Statement.InsertValues) Error!*Plan.Statement {
    // Find the target table
    const table = try p.findTable(stmt.name);
    const full_descr = p.cat.descr.getPtr(table).?;
    // List of expressions for projection
    var scalarNodes =
        std.ArrayList(Plan.ScalarNode).initCapacity(p.alloc, full_descr.attrs.len) catch oom();

    // This is the descriptor of what we get as input data
    const input_descr = p.alloc.create(common.TupleDescriptor) catch oom();
    if (stmt.columns.len > 0) {
        // If the user specified the list of columns, we might need to reorder them for storage.
        input_descr.* = .empty;
        input_descr.attrs.ensureTotalCapacity(p.alloc, stmt.columns.len) catch oom();
        if (stmt.columns.len != full_descr.attrs.len) {
            p.addError("Partial insert is not yet supported", .{});
            return Error.NotSupported;
        }

        _ = scalarNodes.addManyAsSliceAssumeCapacity(full_descr.attrs.len);

        // Go through the columns in the statement
        for (stmt.columns, 0..) |col_name, i| {
            // col_id is the index in the physical table, i is the index in the query
            const col_id = full_descr.findAttribute(col_name);
            if (col_id == null) {
                p.addError("Can't find column \"{s}\" in table \"{s}\"", .{ col_name, stmt.name });
                return Error.UnknownName;
            }
            // Build the descriptor for the input data we get from VALUES part of the query
            input_descr.attrs.appendAssumeCapacity(full_descr.attrs.get(col_id.?));
            // Build an expression for each physical column
            scalarNodes.items[col_id.?] = .{
                .action = .{ .column = @intCast(i) },
                .dbtype = full_descr.attrs.get(col_id.?).t,
            };
        }
    } else {
        input_descr.* = full_descr.clone(p.alloc);
        input_descr.has_extended = false;
    }

    // Plan the VALUES data source
    var root = try p.planValues(stmt.values, input_descr);
    // We always need a projection node to add extended fields
    {
        // Add the projection node on top of VALUES, if needed
        root = p.make(Plan.DataNode{
            .descr = full_descr,
            .action = .{ .project = .{
                .input = root,
                .exprs = scalarNodes.toOwnedSlice(p.alloc) catch oom(),
            } },
        });
    }

    // Finally make the statement node
    return p.make(Plan.Statement{ .insert = .{
        .table = table,
        .root = root,
    } });
}

/// Is the expression a constant?
fn isConstExpression(expr: ast.Expression) bool {
    switch (expr) {
        .variable => return false,
        .integer => return true,
        .string => return true,
        .bool => return true,
        .null => return true,
        .unary => |u| return isConstExpression(u.expr.*),
        .binary => |b| return isConstExpression(b.left.*) and isConstExpression(b.right.*),
        .err => unreachable,
    }
}

/// Evaluate the constant expression
fn evalConstExpression(
    p: *Planner,
    expr: ast.Expression,
    cxt: *const common.TupleDescriptor,
) Error!common.TypedValue {
    const t = try p.inferExprType(expr, cxt);

    switch (expr) {
        .variable => |v| {
            p.addError("Cannot use variable \"{s}\" as a constant", .{v});
            return Error.NotAConstant;
        },
        .integer => |i| return common.TypedValue{
            .v = .{ .int = i },
            .t = t,
        },
        .string => |str| return common.TypedValue{
            .v = .{ .text = str },
            .t = t,
        },
        .bool => |b| return common.TypedValue{
            .v = .{ .bool = b },
            .t = t,
        },
        .null => return common.TypedValue{
            .v = .null,
            .t = .any,
        },
        .unary => |u| {
            const x = try p.evalConstExpression(u.expr.*, cxt);
            switch (u.op) {
                .null => return common.TypedValue{
                    .v = .{ .bool = x.v == .null },
                    .t = t,
                },
                .not_null => return common.TypedValue{
                    .v = .{ .bool = x.v != .null },
                    .t = t,
                },
                .neg => { // -x
                    if (x.v == .null)
                        return x;
                    return common.TypedValue{
                        .v = .{ .int = -x.v.int },
                        .t = t,
                    };
                },
                .not => { // not x
                    if (x.v == .null)
                        return x;
                    return common.TypedValue{
                        .v = .{ .bool = !x.v.bool },
                        .t = t,
                    };
                },
            }
        },
        .binary => |b| {
            const lhs = try p.evalConstExpression(b.left.*, cxt);
            const rhs = try p.evalConstExpression(b.right.*, cxt);
            if (lhs.v == .null or rhs.v == .null)
                return common.TypedValue{
                    .v = .null,
                    .t = t,
                };
            switch (b.op) {
                .add, .sub, .mul, .div => { // +, -, *, /
                    const v = switch (b.op) {
                        .add => lhs.v.int + rhs.v.int,
                        .sub => lhs.v.int - rhs.v.int,
                        .mul => lhs.v.int * rhs.v.int,
                        .div => @divTrunc(lhs.v.int, rhs.v.int),
                        else => unreachable,
                    };
                    return common.TypedValue{
                        .v = .{ .int = v },
                        .t = t,
                    };
                },
                .@"and", .@"or" => { // and, or
                    const v = switch (b.op) {
                        .@"and" => lhs.v.bool and rhs.v.bool,
                        .@"or" => lhs.v.bool or rhs.v.bool,
                        else => unreachable,
                    };
                    return common.TypedValue{
                        .v = .{ .bool = v },
                        .t = t,
                    };
                },
                .eq, .ne => { // =, <>
                    const v = switch (lhs.v) {
                        .null => unreachable,
                        .bool => lhs.v.bool == rhs.v.bool,
                        .int => lhs.v.int == rhs.v.int,
                        .text => std.mem.eql(u8, lhs.v.text.text(), rhs.v.text.text()),
                    };
                    return common.TypedValue{
                        .v = .{ .bool = if (b.op == .eq) v else !v },
                        .t = t,
                    };
                },
                .lt, .gt, .le, .ge => { // <, >, <=, >=
                    const v = switch (b.op) {
                        .lt => lhs.v.int < rhs.v.int,
                        .gt => lhs.v.int > rhs.v.int,
                        .le => lhs.v.int <= rhs.v.int,
                        .ge => lhs.v.int >= rhs.v.int,
                        else => unreachable,
                    };
                    return common.TypedValue{
                        .v = .{ .bool = v },
                        .t = t,
                    };
                },
            }
        },
        .err => unreachable,
    }
}

/// Suggest a name for the column if no explicit alias is given
fn suggestExpressionName(p: *Planner, expr: ast.Expression) Error![]const u8 {
    switch (expr) {
        .variable => |v| return v,
        .integer => |i| return std.fmt.allocPrint(p.alloc, "{}", .{i}) catch oom(),
        .bool => |b| return if (b) "t" else "f",
        .null => return "null",
        .unary, .binary => return "expr",
        .string => |s| return s.text(),
        .err => unreachable,
    }
}

/// Plan SELECT statement
fn planSelect(p: *Planner, stmt: ast.Statement.Select) Error!*Plan.Statement {
    // We don't support joins yet, so only one input table
    if (stmt.sources.len != 1) {
        p.addError("Joins not supported yet", .{});
        return Error.NotSupported;
    }
    // Plan the data source for input
    const source = stmt.sources[0];
    const input_node = try p.planDataSource(source);

    // List of scalar nodes for expressions
    var scalarNodes =
        std.ArrayList(Plan.ScalarNode).initCapacity(p.alloc, stmt.columns.len) catch oom();
    // Go through output columns in the query
    for (stmt.columns) |c| {
        // Build a scalar node for each expression
        const node = try p.planExpression(c.expr.*, input_node.descr);
        scalarNodes.appendAssumeCapacity(node);
    }

    // This is the input data
    var root = input_node;
    // Add a filter if we have a WHERE clause
    if (stmt.where) |condition| {
        const expr = p.make(try p.planExpression(condition.*, root.descr));

        if (expr.dbtype != .bool) {
            p.addError("WHERE clause requires a bool condition, got {}", .{expr.dbtype});
            return Error.TypeError;
        }

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
        // Build the description
        const new_descr = p.make(common.TupleDescriptor.empty);
        new_descr.attrs.ensureTotalCapacity(p.alloc, stmt.columns.len) catch oom();
        for (stmt.columns, scalarNodes.items) |c, n| {
            const name = if (c.alias) |alias|
                alias
            else
                try p.suggestExpressionName(c.expr.*);
            new_descr.attrs.appendAssumeCapacity(.{
                .name = name,
                .t = n.dbtype,
            });
        }

        // Make the projection node
        root = p.make(Plan.DataNode{
            .descr = new_descr,
            .action = .{ .project = .{
                .input = root,
                .exprs = scalarNodes.toOwnedSlice(p.alloc) catch oom(),
            } },
        });
    }

    // Make the statement node
    return p.make(Plan.Statement{ .select = .{ .root = root } });
}

/// Plan DELETE statement
fn planDelete(p: *Planner, stmt: ast.Statement.Delete) Error!*Plan.Statement {
    // Plan the data source for input
    const table = try p.findTable(stmt.name);
    const input_node = try p.planDataSource(.{
        .table = .{ .name = stmt.name },
    });

    // This is the input data
    var root = input_node;
    // Add a filter if we have a WHERE clause
    if (stmt.where) |condition| {
        const expr = p.make(try p.planExpression(condition.*, root.descr));

        if (expr.dbtype != .bool) {
            p.addError("WHERE clause requires a bool condition, got {}", .{expr.dbtype});
            return Error.TypeError;
        }

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
        .table = table,
        .root = root,
    } });
}

/// Plan UPDATE statement
fn planUpdate(p: *Planner, stmt: ast.Statement.Update) Error!*Plan.Statement {
    // Plan the data source for input
    const table = try p.findTable(stmt.name);
    const input_node = try p.planDataSource(.{
        .table = .{ .name = stmt.name },
    });

    // This is the input data
    var root = input_node;
    // Add a filter if we have a WHERE clause
    if (stmt.where) |condition| {
        const expr = p.make(try p.planExpression(condition.*, root.descr));

        if (expr.dbtype != .bool) {
            p.addError("WHERE clause requires a bool condition, got {}", .{expr.dbtype});
            return Error.TypeError;
        }

        root = p.make(Plan.DataNode{
            .descr = root.descr,
            .action = .{ .filter = .{
                .input = root,
                .condition = expr,
            } },
        });
    }

    var cols = std.ArrayList(Plan.ColumnId)
        .initCapacity(p.alloc, stmt.clauses.len) catch oom();
    var vals = std.ArrayList(Plan.ScalarNode)
        .initCapacity(p.alloc, stmt.clauses.len) catch oom();

    for (stmt.clauses) |clause| {
        const col_id = root.descr.findAttribute(clause.column);
        if (col_id == null) {
            p.addError("Can't find column \"{s}\" in table \"{s}\"", .{ clause.column, stmt.name });
            return Error.UnknownName;
        }

        const val = try p.planExpression(clause.expr.*, root.descr);

        cols.appendAssumeCapacity(@intCast(col_id.?));
        vals.appendAssumeCapacity(val);
    }

    // Make the statement node
    return p.make(Plan.Statement{ .update = .{
        .table = table,
        .root = root,
        .cols = cols.toOwnedSlice(p.alloc) catch oom(),
        .vals = vals.toOwnedSlice(p.alloc) catch oom(),
    } });
}

/// Plan a data source node.
/// This is currently very simple because almost nothing is supported.
fn planDataSource(p: *Planner, source: ast.DataSource) Error!*Plan.DataNode {
    switch (source) {
        .table => |t| return try p.planFullScan(t),
        .err => unreachable,
    }
}

/// Plan a full scan node for a table.
fn planFullScan(p: *Planner, table: ast.DataSource.Table) Error!*Plan.DataNode {
    // Find the table in question
    const table_id = try p.findTable(table.name);
    // Find its descriptor
    const descr = p.make(p.cat.descr.get(table_id).?);
    // Build the data source node
    return p.make(Plan.DataNode{
        .descr = descr,
        .action = .{ .full_scan = .{
            .table = table_id,
        } },
    });
}

/// Plan a data source node for VALUES list
fn planValues(
    p: *Planner,
    values: []const ast.ValueList,
    cxt: *const common.TupleDescriptor,
) Error!*Plan.DataNode {
    // The list of tuples in the VALUES
    var values_data =
        std.ArrayList(common.MemTuple).initCapacity(p.alloc, values.len) catch oom();
    // Go through all the rows in the query
    for (values) |row| {
        // Check the row lengths
        if (row.columns.len != cxt.attrs.len) {
            p.addError(
                "Expected {} values but got {}",
                .{ cxt.attrs.len, row.columns.len },
            );
            return Error.Other;
        }

        // Build the tuple
        var b = common.MemTuple.Builder.init(p.alloc, cxt);
        for (row.columns, cxt.attrs.items(.t)) |expr, t| {
            const val = try p.evalConstExpression(expr, cxt);
            // Check the type of the value
            if (!val.t.convertsTo(t)) {
                p.addError("Expected type {} but got {}", .{ t, val });
                return Error.TypeError;
            }
            b.pushValue(val.v);
        }
        values_data.appendAssumeCapacity(b.finalize());
    }

    // Build the data source node
    return p.make(Plan.DataNode{
        .descr = cxt,
        .action = .{ .values = .{
            .data = values_data.toOwnedSlice(p.alloc) catch oom(),
        } },
    });
}

/// Try to infer a type of an expression, given the context of the currently available variables.
fn inferExprType(p: *Planner, expr: ast.Expression, cxt: *const common.TupleDescriptor) Error!common.DBType {
    switch (expr) {
        .variable => |v| { // Variable expression
            // Find the column
            const col_id = cxt.findAttribute(v);
            if (col_id == null) {
                p.addError("Can't find variable \"{s}\"", .{v});
                return Error.UnknownName;
            }
            // Construct the scalar node
            return cxt.attrs.get(col_id.?).t;
        },
        .integer => return .int4,
        .string => return .text,
        .bool => return .bool,
        .null => return .any,
        .unary => |u| {
            const child = try p.inferExprType(u.expr.*, cxt);
            switch (u.op) {
                .not, .neg => return child,
                .null, .not_null => return .bool,
            }
        },
        .binary => |u| {
            const lhs = try p.inferExprType(u.left.*, cxt);
            const rhs = try p.inferExprType(u.right.*, cxt);
            switch (u.op) {
                .add, .sub, .mul, .div => { // Can do arithmetic only on numbers
                    if (!lhs.isNumber()) {
                        p.addError("Cannot use arithmetic operator on type {}", .{lhs});
                        return Error.TypeError;
                    } else if (!rhs.isNumber()) {
                        p.addError("Cannot use arithmetic operator on type {}", .{rhs});
                        return Error.TypeError;
                    } else return lhs.maxIntType(rhs);
                },
                .@"and", .@"or" => { // Can do and/or only on booleans
                    if (lhs != .bool) {
                        p.addError("Cannot use logic operator on type {}", .{lhs});
                        return Error.TypeError;
                    } else if (lhs != .bool) {
                        p.addError("Cannot use logic operator on type {}", .{rhs});
                        return Error.TypeError;
                    } else return .bool;
                },
                .eq, .ne => { // Can check equality of numbers and values of the same type
                    const both_numbers = lhs.isNumber() and rhs.isNumber();
                    const same_type = std.meta.eql(lhs, rhs);
                    if (!both_numbers and !same_type) {
                        p.addError("Cannot compare types {} and {}", .{ lhs, rhs });
                        return Error.TypeError;
                    } else return .bool;
                },
                .lt, .gt, .le, .ge => { // Can only compare numbers
                    const both_numbers = lhs.isNumber() and rhs.isNumber();
                    if (!both_numbers) {
                        p.addError("Cannot compare types {} and {}", .{ lhs, rhs });
                        return Error.TypeError;
                    } else return .bool;
                },
            }
        },
        .err => unreachable,
    }
}

/// Plan the scalar node for an expression (in the context of some tuple descriptor).
fn planExpression(
    p: *Planner,
    expr: ast.Expression,
    cxt: *const common.TupleDescriptor,
) Error!Plan.ScalarNode {
    // Fast path for constant expressions
    if (isConstExpression(expr)) {
        // Evaluate the constant
        const v = try p.evalConstExpression(expr, cxt);
        // Construct the expression
        return Plan.ScalarNode{
            .action = .{ .value = v.v },
            .dbtype = v.t,
        };
    }

    // Calculate the resulting type
    const t = try p.inferExprType(expr, cxt);

    switch (expr) {
        .variable => |v| { // Variable expression
            // Find the column
            const col_id = cxt.findAttribute(v);
            if (col_id == null) {
                p.addError("Can't find variable \"{s}\"", .{v});
                return Error.UnknownName;
            }
            // Construct the scalar node
            return Plan.ScalarNode{
                .action = .{ .column = @intCast(col_id.?) },
                .dbtype = t,
            };
        },
        .unary => |u| {
            const child = p.make(try p.planExpression(u.expr.*, cxt));
            return Plan.ScalarNode{
                .action = .{ .unary = .{
                    .op = u.op,
                    .child = child,
                } },
                .dbtype = t,
            };
        },
        .binary => |b| {
            const left = p.make(try p.planExpression(b.left.*, cxt));
            const right = p.make(try p.planExpression(b.right.*, cxt));
            return Plan.ScalarNode{
                .action = .{ .binary = .{
                    .op = b.op,
                    .left = left,
                    .right = right,
                } },
                .dbtype = t,
            };
        },
        .integer, .string, .bool, .null => unreachable, // This is supposed to be a constant
        .err => unreachable,
    }
}
