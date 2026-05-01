//! This is a planner, the object that forms a plan from a statement from its AST.

const std = @import("std");

const Plan = @import("Plan.zig");
const ast = @import("../sql/ast.zig");
const data = @import("../data.zig");
const ids = @import("../ids.zig");
const catalog = @import("../catalog.zig");
const oom = @import("../utils.zig").oom;

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

/// Plan a statement
pub fn plan(p: *Planner, stmt: ast.Statement) Error!*Plan.Statement {
    switch (stmt) {
        .create_table => return p.planCreateTable(stmt.create_table),
        .drop_table => return p.planDropTable(stmt.drop_table),
        .select => return p.planSelect(stmt.select),
        .insert_values => return p.planInsertValues(stmt.insert_values),
        .truncate => return p.planTruncate(stmt.truncate),
        .err => unreachable,
    }
}

/// Plan CREATE TABLE statement
fn planCreateTable(p: *Planner, stmt: ast.Statement.CreateTable) Error!*Plan.Statement {
    // Build the TupleDescriptor for the new table
    const descr = p.alloc.create(data.TupleDescriptor) catch oom();
    descr.* = data.TupleDescriptor.empty;
    descr.attrs.ensureUnusedCapacity(
        p.alloc,
        stmt.columns.items.len,
    ) catch oom();
    for (stmt.columns.items) |c| {
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
    const result = p.alloc.create(Plan.Statement) catch oom();
    result.* = .{ .create_table = .{
        .name = lower_name,
        .descr = descr,
    } };
    return result;
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
    const result = p.alloc.create(Plan.Statement) catch oom();
    result.* = .{ .drop_table = .{
        .table = try p.findTable(stmt.name),
    } };
    return result;
}

/// Plan TRUNCATE statement
fn planTruncate(p: *Planner, stmt: ast.Statement.Truncate) Error!*Plan.Statement {
    const result = p.alloc.create(Plan.Statement) catch oom();
    result.* = .{ .truncate = .{
        .table = try p.findTable(stmt.name),
    } };
    return result;
}

/// Plan INSERT VALUES statement
fn planInsertValues(p: *Planner, stmt: ast.Statement.InsertValues) Error!*Plan.Statement {
    // Find the target table
    const table = try p.findTable(stmt.name);
    const full_descr = p.cat.descr.getPtr(table).?;
    // List of expressions for projection
    var scalarNodes =
        std.ArrayList(Plan.ScalarNode).initCapacity(p.alloc, full_descr.attrs.len) catch oom();
    _ = scalarNodes.addManyAsSliceAssumeCapacity(full_descr.attrs.len);

    // This is the descriptor of what we get as input data
    var input_descr = full_descr;
    var need_project = false;
    if (stmt.columns.items.len > 0) {
        // If the user specified the list of columns, we might need to reorder them for storage.
        input_descr = p.alloc.create(data.TupleDescriptor) catch oom();
        input_descr.* = .empty;
        input_descr.attrs.ensureTotalCapacity(p.alloc, stmt.columns.items.len) catch oom();
        if (stmt.columns.items.len != full_descr.attrs.len) {
            p.addError("Partial insert is not yet supported", .{});
            return Error.NotSupported;
        }

        // Go through the columns in the statement
        for (stmt.columns.items, 0..) |col_name, i| {
            // col_id is the index in the physical table, i is the index in the query
            const col_id = full_descr.findAttribute(col_name);
            if (col_id == null) {
                p.addError("Can't find column \"{s}\" in table \"{s}\"", .{ col_name, stmt.name });
                return Error.UnknownName;
            }
            // If they don't match, we need a projection node
            if (col_id.? != i)
                need_project = true;
            // Build the descriptor for the input data we get from VALUES part of the query
            input_descr.attrs.appendAssumeCapacity(full_descr.attrs.get(col_id.?));
            // Build an expression for each physical column
            scalarNodes.items[col_id.?] = .{
                .action = .{ .column = @intCast(i) },
                .dbtype = full_descr.attrs.get(col_id.?).t,
            };
        }
    }

    // Plan the VALUES data source
    var root = try p.planValues(&stmt.values, input_descr);
    if (need_project) {
        // Add the projection node on top of VALUES, if needed
        const project_node = p.alloc.create(Plan.DataNode) catch oom();
        project_node.* = .{
            .descr = full_descr,
            .action = .{ .project = .{
                .input = root,
                .exprs = scalarNodes,
            } },
        };
        root = project_node;
    }

    // Finally create the statement node
    const result = p.alloc.create(Plan.Statement) catch oom();
    result.* = .{ .insert = .{
        .table = table,
        .root = root,
    } };
    return result;
}

/// Is the expression a constant?
fn isConstExpression(expr: ast.Expression) bool {
    switch (expr) {
        .variable => return false,
        .integer => return true,
        else => unreachable,
    }
}

/// Evaluate the constant expression
fn evalConstExpression(p: *Planner, expr: ast.Expression) Error!data.TypedValue {
    switch (expr) {
        .variable => |v| {
            p.addError("Cannot use variable \"{s}\" as a constant", .{v});
            return Error.NotAConstant;
        },
        .integer => |i| return data.TypedValue{
            .v = .{ .int = i },
            .t = .int4,
        },
        else => unreachable,
    }
}

/// Suggest a name for the column if no explicit alias is given
fn suggestExpressionName(p: *Planner, expr: ast.Expression) Error![]const u8 {
    switch (expr) {
        .variable => |v| return v,
        .integer => |i| return std.fmt.allocPrint(p.alloc, "num{}", .{i}) catch oom(),
        else => unreachable,
    }
}

/// Plan SELECT statement
fn planSelect(p: *Planner, stmt: ast.Statement.Select) Error!*Plan.Statement {
    // We don't support joins yet, so only one input table
    if (stmt.sources.items.len != 1) {
        p.addError("Joins not supported yet", .{});
        return Error.NotSupported;
    }
    // Plan the data source for input
    const source = stmt.sources.items[0];
    const input_node = try p.planDataSource(source);

    // The SELECT might contain expression that might need projection
    var need_project = stmt.columns.items.len != input_node.descr.attrs.len;
    // List of scalar nodes for expressions
    var scalarNodes =
        std.ArrayList(Plan.ScalarNode).initCapacity(p.alloc, stmt.columns.items.len) catch oom();
    // Go through output columns in the query
    for (stmt.columns.items, 0..) |c, i| {
        // Build a scalar node for each expression
        const node = try p.planExpression(c, input_node.descr);
        // We don't need projection only if all the expression are column names in the correct order.
        // Otherwise, we do need a projection.
        switch (node.action) {
            .column => |j| if (i != j) {
                need_project = true;
            },
            else => need_project = true,
        }
        scalarNodes.appendAssumeCapacity(node);
    }

    // This is the input data
    var root = input_node;
    // Add a projection node if needed
    if (need_project) {
        // Build the description
        const new_descr = p.alloc.create(data.TupleDescriptor) catch oom();
        new_descr.* = .empty;
        new_descr.attrs.ensureTotalCapacity(p.alloc, stmt.columns.items.len) catch oom();
        for (stmt.columns.items, scalarNodes.items) |c, n| {
            new_descr.attrs.appendAssumeCapacity(.{
                .name = try p.suggestExpressionName(c),
                .t = n.dbtype,
            });
        }

        // Create the projection node
        const project_node = p.alloc.create(Plan.DataNode) catch oom();
        project_node.* = .{
            .descr = new_descr,
            .action = .{ .project = .{
                .input = root,
                .exprs = scalarNodes,
            } },
        };
        root = project_node;
    }

    // Create the statement node
    const result = p.alloc.create(Plan.Statement) catch oom();
    result.* = .{ .select = .{ .root = root } };
    return result;
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
    const descr = p.alloc.create(data.TupleDescriptor) catch oom();
    descr.* = p.cat.descr.get(table_id).?;
    // Build the data source node
    const result = p.alloc.create(Plan.DataNode) catch oom();
    result.* = .{
        .descr = descr,
        .action = .{ .full_scan = .{
            .table = table_id,
        } },
    };
    return result;
}

/// Plan a data source node for VALUES list
fn planValues(
    p: *Planner,
    values: *const std.ArrayList(ast.ValueList),
    descr: *const data.TupleDescriptor,
) Error!*Plan.DataNode {
    // The list of tuples in the VALUES
    var values_data =
        std.ArrayList(data.MemTuple).initCapacity(p.alloc, values.items.len) catch oom();
    // Go through all the rows in the query
    for (values.items) |row| {
        // Check the row lengths
        if (row.columns.items.len != descr.attrs.len) {
            p.addError(
                "Expected {} values but got {}",
                .{ descr.attrs.len, row.columns.items.len },
            );
            return Error.Other;
        }

        // Build the tuple
        var b = data.MemTuple.Builder.init(p.alloc, descr);
        for (row.columns.items, descr.attrs.items(.t)) |expr, t| {
            const val = try p.evalConstExpression(expr);
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
    const data_node = p.alloc.create(Plan.DataNode) catch oom();
    data_node.* = .{
        .descr = descr,
        .action = .{ .values = .{ .data = values_data } },
    };
    return data_node;
}

// Plan the scalar node for an expression (in the context of some tuple descriptor).
fn planExpression(
    p: *Planner,
    expr: ast.Expression,
    cxt: *const data.TupleDescriptor,
) Error!Plan.ScalarNode {
    // Fast return for constant expressions
    if (isConstExpression(expr)) {
        // Evaluate the constant
        const v = try p.evalConstExpression(expr);
        // Construct the expression
        return Plan.ScalarNode{
            .action = .{ .value = v.v },
            .dbtype = v.t,
        };
    }

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
                .dbtype = cxt.attrs.get(col_id.?).t,
            };
        },
        .integer => unreachable, // This is supposed to be a constant
        else => unreachable,
    }
}
