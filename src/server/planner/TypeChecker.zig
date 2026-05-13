const std = @import("std");

const ast = @import("../sql/ast.zig");
const common = @import("common");
const DBType = common.DBType;
const TupleDescriptor = common.TupleDescriptor;
const ids = common.ids;
const catalog = @import("../catalog.zig");
const oom = common.oom;

const TypeChecker = @This();

/// Allocator for the errors
alloc: std.mem.Allocator,
/// Catalog cache to read metadata
cat: *catalog.Cache,
/// Type checking errors
errors: std.ArrayList([]const u8),

pub const Error = error{
    UnknownName,
    AmbiguousName,
    NotAConstant,
    TypeError,
    Other,
};

/// Initialize the type checker
pub fn init(alloc: std.mem.Allocator, cat: *catalog.Cache) TypeChecker {
    return TypeChecker{
        .alloc = alloc,
        .cat = cat,
        .errors = .empty,
    };
}

/// Type check statement
pub fn check(t: *TypeChecker, stmt: *ast.Statement) bool {
    switch (stmt.*) {
        .create_table => return true,
        .drop_table => return t.checkDropTable(&stmt.drop_table),
        .select => return t.checkSelect(&stmt.select),
        .@"union" => return t.checkUnion(&stmt.@"union"),
        .delete => return t.checkDelete(&stmt.delete),
        .insert_values => return t.checkInsertValues(&stmt.insert_values),
        .update => return t.checkUpdate(&stmt.update),
        .truncate => return t.checkTruncate(&stmt.truncate),
        .begin, .commit, .rollback => return true,
        .err => unreachable,
    }
}

/// Finds a table by its name
fn findTable(t: *TypeChecker, name: *ast.Name) Error!catalog.Entry(.zdb_rels) {
    // Scan through the catalog
    var scanner = t.cat.catalog.zdb_rels.scanTextIgnoreCase(
        .rel_name,
        name.text,
        &.{},
        &.{},
    );
    const table = scanner.next();
    if (table) |entry| {
        name.id = entry.rel_id;
        // If found, return it
        return entry;
    } else {
        // If not found, emit error
        t.addError("Unknown table \"{s}\"", .{name.text});
        return Error.UnknownName;
    }
}

/// Adds a formatted error to the error list.
fn addError(t: *TypeChecker, comptime fmt: []const u8, args: anytype) void {
    const str = std.fmt.allocPrint(
        t.alloc,
        fmt,
        args,
    ) catch oom();
    t.errors.append(t.alloc, str) catch oom();
}

/// Find the index of an attribute given its name.
/// Returns null if there is no such attribute.
pub fn findAttribute(
    t: *TypeChecker,
    td: *const TupleDescriptor,
    name: *ast.Name,
    table: ?ast.Name,
) Error!?usize {
    var result: ?usize = null;
    for (td.attrs.items, 0..) |att, i| {
        if (table) |tn|
            if (!std.ascii.eqlIgnoreCase(att.table_name, tn.text))
                continue;
        if (std.ascii.eqlIgnoreCase(att.name, name.text)) {
            if (result != null) {
                t.addError("Name \"{s}\" is ambiguous, please specify a table", .{att.name});
                return Error.AmbiguousName;
            }
            result = i;
            name.id = @intCast(i);
        }
    }
    return result;
}

/// Check DROP TABLE statement
fn checkDropTable(t: *TypeChecker, stmt: *ast.Statement.DropTable) bool {
    _ = t.findTable(&stmt.name) catch return false;
    return true;
}

/// Check TRUNCATE statement
fn checkTruncate(t: *TypeChecker, stmt: *ast.Statement.Truncate) bool {
    _ = t.findTable(&stmt.name) catch return false;
    return true;
}

/// Check INSERT VALUES statement
fn checkInsertValues(t: *TypeChecker, stmt: *ast.Statement.InsertValues) bool {
    // Find the target table
    const table = t.findTable(&stmt.name) catch return false;
    const full_descr = t.cat.descr.getPtr(table.rel_id).?;

    // This is the descriptor of what we get as input data
    const input_descr = t.alloc.create(TupleDescriptor) catch oom();
    input_descr.* = .empty;
    if (stmt.columns.len > 0) {
        // Is the column value given?
        var column_given =
            std.DynamicBitSetUnmanaged.initEmpty(t.alloc, full_descr.len()) catch oom();
        // If the user specified the list of columns, we might need to reorder them for storage.
        input_descr.attrs.ensureTotalCapacity(t.alloc, stmt.columns.len) catch oom();

        // Go through the columns in the statement
        var err = false;
        for (stmt.columns) |*col_name| {
            // col_id is the index in the physical table, i is the index in the query
            const col_id = t.findAttribute(
                full_descr,
                col_name,
                null,
            ) catch {
                err = true;
                continue;
            };
            if (col_id == null) {
                t.addError("Can't find column \"{s}\" in table \"{s}\"", .{ col_name.text, stmt.name.text });
                err = true;
                continue;
            }
            // Build the descriptor for the input data we get from VALUES part of the query
            input_descr.attrs.appendAssumeCapacity(full_descr.attrs.items[col_id.?]);
            // Mark the column as used
            column_given.set(col_id.?);
        }
        if (err) return false;

        // Fill in missing columns with default values
        for (full_descr.attrs.items, 0..) |att, i| {
            if (column_given.isSet(i)) continue;
            if (att.t != .serial) {
                t.addError(
                    "Missing value for column \"{s}\" in table \"{s}\"",
                    .{ att.name, stmt.name.text },
                );
                err = true;
                continue;
            }
        }
        if (err) return false;
    } else {
        input_descr.* = full_descr.*.clone(t.alloc);
        input_descr.has_extended = false;
    }

    stmt.values.t = input_descr;

    // Check the VALUES data source
    return t.checkValues(stmt.values);
}

/// Suggest a name for the column if no explicit alias is given
fn suggestExpressionName(t: *TypeChecker, expr: ast.Expression) Error![]const u8 {
    switch (expr.u) {
        .variable => |v| return v.name.text,
        .value => |v| switch (v) {
            .int => |i| return std.fmt.allocPrint(t.alloc, "{}", .{i}) catch oom(),
            .boolean => |b| return if (b) "t" else "f",
            .null => return "null",
            .uuid => return "uuid",
            .text => |s| return s.text(),
        },
        .unary, .binary => return "expr",
        .err => unreachable,
    }
}

/// Check SELECT statement
fn checkSelect(t: *TypeChecker, stmt: *ast.Statement.Select) bool {
    // Check the data source for input
    if (!t.checkDataSource(stmt.source, false)) return false;

    // Go through output columns in the query
    var err = false;
    for (stmt.columns) |c| {
        // Build a scalar node for each expression
        switch (c) {
            .normal => |n| {
                _ = t.checkExprType(n.expr, .any, stmt.source.t.?) catch {
                    err = true;
                    continue;
                };
            },
            .star => {},
        }
    }
    if (err) return false;

    // Check a WHERE clause
    if (stmt.where) |condition| {
        _ = t.checkExprType(
            condition,
            .{ .db = .boolean },
            stmt.source.t.?,
        ) catch {
            return false;
        };
    }
    return true;
}

/// Check UNION statement
fn checkUnion(t: *TypeChecker, stmt: *ast.Statement.Union) bool {
    var err = false;
    for (stmt.stmts) |*child| {
        if (!t.check(child)) {
            err = true;
            continue;
        }
        std.debug.assert(child.* == .select);
    }
    if (err) return false;
    std.debug.assert(stmt.stmts.len > 0);

    for (stmt.stmts) |source| {
        if (!source.select.source.t.?.eql(stmt.stmts[0].select.source.t.?)) {
            t.addError("Two sides of the UNION must match!", .{});
            return false;
        }
    }
    return true;
}

/// Check DELETE statement
fn checkDelete(t: *TypeChecker, stmt: *ast.Statement.Delete) bool {
    // Check the data source for input
    const table = t.findTable(&stmt.name) catch return false;
    const full_descr = t.cat.descr.getPtr(table.rel_id).?;

    // Check WHERE condition
    if (stmt.where) |condition| {
        _ = t.checkExprType(
            condition,
            .{ .db = .boolean },
            full_descr,
        ) catch {
            return false;
        };
    }
    return true;
}

/// Check UPDATE statement
fn checkUpdate(t: *TypeChecker, stmt: *ast.Statement.Update) bool {
    // Check the data source for input
    const table = t.findTable(&stmt.name) catch return false;
    const full_descr = t.cat.descr.getPtr(table.rel_id).?;

    // Check WHERE condition
    if (stmt.where) |condition| {
        _ = t.checkExprType(
            condition,
            .{ .db = .boolean },
            full_descr,
        ) catch {
            return false;
        };
    }

    var err = false;
    for (stmt.clauses) |*clause| {
        const col_id = t.findAttribute(
            full_descr,
            &clause.column,
            null,
        ) catch {
            err = true;
            continue;
        };
        if (col_id == null) {
            t.addError("Can't find column \"{s}\" in table \"{s}\"", .{ clause.column.text, stmt.name.text });
            err = true;
            continue;
        }

        _ = t.checkExprType(
            clause.expr,
            .{ .db = full_descr.attrs.items[col_id.?].t },
            full_descr,
        ) catch {
            err = true;
            continue;
        };
    }
    return !err;
}

/// Is the expression a constant?
fn isConstExpression(expr: ast.Expression) bool {
    switch (expr.u) {
        .variable => return false,
        .value => return true,
        .unary => |u| return isConstExpression(u.expr.*),
        .binary => |b| return isConstExpression(b.left.*) and isConstExpression(b.right.*),
        .err => unreachable,
    }
}

/// Evaluate the constant expression
fn evalConstExpression(
    t: *TypeChecker,
    expr: *ast.Expression,
    cxt: *const common.TupleDescriptor,
) Error!common.Value {
    switch (expr.u) {
        .variable => |v| {
            t.addError("Cannot use variable \"{s}\" as a constant", .{v.name.text});
            return Error.NotAConstant;
        },
        .value => |v| return v,
        .unary => |u| {
            const x = try t.evalConstExpression(u.expr, cxt);
            switch (u.op) {
                .null => return .{ .boolean = x == .null },
                .not_null => return .{ .boolean = x != .null },
                .neg => { // -x
                    if (x == .null)
                        return x;
                    return .{ .int = -x.int };
                },
                .not => { // not x
                    if (x == .null)
                        return x;
                    return .{ .boolean = !x.boolean };
                },
            }
        },
        .binary => |b| {
            const lhs = try t.evalConstExpression(b.left, cxt);
            const rhs = try t.evalConstExpression(b.right, cxt);
            if (lhs == .null or rhs == .null)
                return .null;
            switch (b.op) {
                .add, .sub, .mul, .div => { // +, -, *, /
                    const v = switch (b.op) {
                        .add => lhs.int + rhs.int,
                        .sub => lhs.int - rhs.int,
                        .mul => lhs.int * rhs.int,
                        .div => @divTrunc(lhs.int, rhs.int),
                        else => unreachable,
                    };
                    return .{ .int = v };
                },
                .@"and", .@"or" => { // and, or
                    const v = switch (b.op) {
                        .@"and" => lhs.boolean and rhs.boolean,
                        .@"or" => lhs.boolean or rhs.boolean,
                        else => unreachable,
                    };
                    return .{ .boolean = v };
                },
                .eq, .ne => { // =, <>
                    const v = switch (lhs) {
                        .null => unreachable,
                        .boolean => lhs.boolean == rhs.boolean,
                        .int => lhs.int == rhs.int,
                        .uuid => lhs.uuid == rhs.uuid,
                        .text => std.mem.eql(u8, lhs.text.text(), rhs.text.text()),
                    };
                    return .{ .boolean = if (b.op == .eq) v else !v };
                },
                .lt, .gt, .le, .ge => { // <, >, <=, >=
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
        .err => unreachable,
    }
}

const TypeRequest = union(enum) {
    db: DBType, // Or rather, type implicitly convertible to this
    any_int: void,
    any_text: void,
    any: void,

    fn fulfilled(r: TypeRequest, o: DBType) bool {
        switch (r) {
            .db => |rdb| return o.convertsTo(rdb),
            .any_int => return o.isNumber(),
            .any_text => return o == .text or o == .long_text,
            .any => return true,
        }
    }
};

/// Try to infer a type of an expression, given the context of the currently available variables.
fn checkExprType(
    t: *TypeChecker,
    expr: *ast.Expression,
    request: TypeRequest,
    cxt: *const TupleDescriptor,
) Error!DBType {
    const expr_type: DBType = expr_type: switch (expr.u) {
        .variable => |*v| { // Variable expression
            // Find the column
            const col_id = try t.findAttribute(cxt, &v.name, v.table);
            if (col_id == null) {
                t.addError("Can't find variable \"{s}\"", .{v.name.text});
                return Error.UnknownName;
            }
            // Construct the scalar node
            break :expr_type cxt.attrs.items[col_id.?].t;
        },
        .value => |v| {
            if (request == .db) {
                switch (v) {
                    .int => if (!request.db.isNumber()) {
                        t.addError("Expected {} but got integer constant", .{request});
                        return Error.TypeError;
                    },
                    .text => if (request.db != .text and request.db != .long_text) {
                        t.addError("Expected {} but got text constant", .{request});
                        return Error.TypeError;
                    },
                    .boolean => if (request.db != .boolean) {
                        t.addError("Expected {} but got boolean constant", .{request});
                        return Error.TypeError;
                    },
                    .null => {},
                    .uuid => if (request.db != .uuid) {
                        t.addError("Expected {} but got uuid constant", .{request});
                        return Error.TypeError;
                    },
                }
                break :expr_type request.db;
            } else switch (v) {
                .int => break :expr_type .int4,
                .text => break :expr_type .text,
                .boolean => break :expr_type .boolean,
                .null => break :expr_type .nulltype,
                .uuid => break :expr_type .uuid,
            }
        },
        .unary => |u| {
            switch (u.op) {
                .not => {
                    _ = try t.checkExprType(u.expr, .{ .db = .boolean }, cxt);
                    break :expr_type .boolean;
                },
                .neg => {
                    const dbtype = try t.checkExprType(u.expr, request, cxt);
                    break :expr_type dbtype;
                },
                .null, .not_null => {
                    _ = try t.checkExprType(u.expr, .any, cxt);
                    break :expr_type .boolean;
                },
            }
        },
        .binary => |u| {
            switch (u.op) {
                .add, .sub, .mul, .div => { // Can do arithmetic only on numbers
                    const lhs = try t.checkExprType(u.left, request, cxt);
                    const rhs = try t.checkExprType(u.right, request, cxt);
                    if (!request.fulfilled(lhs)) {
                        t.addError("Cannot use arithmetic operator on type {}", .{lhs});
                        return Error.TypeError;
                    }
                    if (!request.fulfilled(rhs)) {
                        t.addError("Cannot use arithmetic operator on type {}", .{rhs});
                        return Error.TypeError;
                    }
                    break :expr_type lhs.maxIntType(rhs);
                },
                .@"and", .@"or" => { // Can do and/or only on booleans
                    _ = try t.checkExprType(u.left, .{ .db = .boolean }, cxt);
                    _ = try t.checkExprType(u.right, .{ .db = .boolean }, cxt);
                    break :expr_type .boolean;
                },
                .eq, .ne => { // Can check equality of numbers and values of the same type
                    const lhs = try t.checkExprType(u.left, .any, cxt);
                    const rhs = try t.checkExprType(u.right, .any, cxt);
                    const both_numbers = lhs.isNumber() and rhs.isNumber();
                    const same_type = std.meta.eql(lhs, rhs);
                    if (!both_numbers and !same_type) {
                        t.addError("Cannot compare types {} and {}", .{ lhs, rhs });
                        return Error.TypeError;
                    } else break :expr_type .boolean;
                },
                .lt, .gt, .le, .ge => { // Can only compare numbers
                    _ = try t.checkExprType(u.left, .any_int, cxt);
                    _ = try t.checkExprType(u.right, .any_int, cxt);
                    break :expr_type .boolean;
                },
            }
        },
        .err => unreachable,
    };
    if (!request.fulfilled(expr_type)) {
        t.addError("Expected {} but got type {}", .{ request, expr_type });
        return Error.TypeError;
    }
    if (request == .db)
        expr.t = request.db
    else
        expr.t = expr_type;
    if (isConstExpression(expr.*) and expr.u != .value) {
        const v = try t.evalConstExpression(expr, cxt);
        expr.u = .{ .value = v };
    }
    return expr.t.?;
}

fn checkDataSource(t: *TypeChecker, ds: *ast.DataSource, need_extended: bool) bool {
    switch (ds.u) {
        .table => return t.checkTableSource(ds),
        .join => return t.checkJoin(ds, need_extended),
        .values => return t.checkValues(ds),
        .err => unreachable,
    }
}

fn checkTableSource(t: *TypeChecker, ds: *ast.DataSource) bool {
    std.debug.assert(ds.u == .table);
    const table = t.findTable(&ds.u.table.name) catch return false;
    const full_descr = t.cat.descr.getPtr(table.rel_id).?;
    ds.t = full_descr;
    if (ds.alias) |ta| {
        const new = t.alloc.create(TupleDescriptor) catch oom();
        new.* = full_descr.clone(t.alloc);
        for (new.attrs.items) |*att|
            att.table_name = ta.text;
        ds.t = new;
    }
    return true;
}

fn checkJoin(t: *TypeChecker, ds: *ast.DataSource, need_extended: bool) bool {
    const lhs_res = t.checkDataSource(ds.u.join.lhs, need_extended);
    const rhs_res = t.checkDataSource(ds.u.join.rhs, false);
    if (!lhs_res or !rhs_res) return false;

    const lhs = ds.u.join.lhs.t.?;
    const rhs = ds.u.join.rhs.t.?;

    const new_descr = t.alloc.create(TupleDescriptor) catch oom();
    new_descr.* = lhs.clone(t.alloc);
    new_descr.attrs.ensureUnusedCapacity(
        t.alloc,
        rhs.len(),
    ) catch oom();
    new_descr.attrs.appendSliceAssumeCapacity(rhs.attrs.items);
    new_descr.has_extended = need_extended;
    // Change table alias if we have one
    ds.t = new_descr;
    if (ds.alias) |ta| {
        for (new_descr.attrs.items) |*att|
            att.table_name = ta.text;
        ds.t = new_descr;
    }
    // Check the join condition
    if (ds.u.join.cond) |c|
        _ = t.checkExprType(c, .{ .db = .boolean }, new_descr) catch return false;

    return true;
}

/// Check a data source node for VALUES list
fn checkValues(
    t: *TypeChecker,
    ds: *ast.DataSource,
) bool {
    std.debug.assert(ds.u == .values);
    std.debug.assert(ds.t != null);

    var err = false;
    // Go through all the rows in the query
    for (ds.u.values.data) |row| {
        // Check the row lengths
        if (row.len != ds.t.?.len()) {
            t.addError(
                "Expected {} values but got {}",
                .{ ds.t.?.len(), row.len },
            );
            err = true;
            continue;
        }

        // Check the tuple
        for (row, ds.t.?.attrs.items) |*expr, att| {
            _ = t.checkExprType(expr, .{ .db = att.t }, ds.t.?) catch {
                err = true;
                continue;
            };
        }
    }

    return !err;
}
