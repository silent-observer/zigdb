//! This is a recursive descent parser for SQL
//! It is not particularly optimized and the errors aren't great,
//! so it should probably be reworked in the future.

const std = @import("std");
const Lexer = @import("Lexer.zig");
const ast = @import("ast.zig");
const common = @import("common");
const DBType = common.DBType;
const oom = common.oom;

const Parser = @This();

alloc: std.mem.Allocator, // Allocator for the AST
input: []const u8, // Input text
tokens: std.MultiArrayList(Lexer.Token), // List of tokens
pos: usize, // Current position in the list of tokens
errors: std.ArrayList([]const u8), // List of parsing errors (as text)

/// Initialize the parser
pub fn init(alloc: std.mem.Allocator) Parser {
    return .{
        .alloc = alloc,
        .input = &.{},
        .tokens = .empty,
        .pos = 0,
        .errors = .empty,
    };
}

/// Lex an input string, possibly producing a lexing error.
/// Must be done before parsing.
pub fn lex(p: *Parser, input: []const u8) ?Lexer.Error {
    var lexer = Lexer.init(p.alloc, input);
    if (lexer.lex()) |err| return err;
    p.input = input;
    p.tokens = lexer.finalize();
    return null;
}

/// Calculate line+column of a token. Used for error output.
fn calcLineCol(input: []const u8, pos: usize) struct { line: usize, col: usize } {
    std.debug.assert(pos < input.len);

    var line: usize = 1; // Current line
    var to_skip: usize = pos; // How many characters are left to skip
    var offset: usize = 0; // How many we have already skipped (always pos - to_skip)

    // Find the next newline starting from offset
    while (std.mem.findScalar(u8, input[offset..], '\n')) |next_newline| {
        // If the target position is before the next newline, we are done
        if (to_skip < next_newline)
            break;
        // Advance to the next line
        offset += next_newline;
        to_skip -= next_newline;
        line += 1;
    }
    // We have reached the correct line, now the column is
    // however many characters are still left to skip.
    return .{ .line = line, .col = 1 + to_skip };
}

/// Add a formatted error message to the list of errors.
fn addError(p: *Parser, t: Lexer.Token, comptime fmt: []const u8, args: anytype) void {
    const r = calcLineCol(p.input, t.start);
    const str = std.fmt.allocPrint(
        p.alloc,
        fmt ++ " at {}:{}", // This adds a line:column text to the error message
        args ++ .{ r.line, r.col },
    ) catch oom();
    p.errors.append(p.alloc, str) catch oom();
}

/// Get the next token (or EOF token if we are at the end).
fn peek(p: *const Parser) Lexer.Token {
    if (p.pos < p.tokens.len)
        return p.tokens.get(p.pos)
    else
        return .{
            .kind = .eof,
            .start = @intCast(p.pos),
            .end = @intCast(p.pos),
        };
}

/// Advance the parser by one token.
fn advance(p: *Parser) void {
    if (p.pos < p.tokens.len)
        p.pos += 1;
}

/// Look at the current token and advance if it is what we expect.
fn eat(p: *Parser, kind: Lexer.Token.Kind) bool {
    if (p.peek().matches(kind)) {
        p.advance();
        return true;
    } else return false;
}

const InternalError = error{
    UnexpectedToken,
};

/// Look at the current token and advance if it is what we expect.
/// Throw an error if it doesn't match.
fn expect(p: *Parser, kind: Lexer.Token.Kind) InternalError!void {
    if (!p.eat(kind)) {
        p.addError(
            p.peek(),
            "Expected {} but got \"{s}\"",
            .{ kind, p.peek().text(p.input) },
        );
        return InternalError.UnexpectedToken;
    }
}

/// Look at the current token and advance if it is a keyword that we expect.
/// Throw an error if it doesn't match.
fn expectKeyword(p: *Parser, kw: Lexer.Token.Keyword) InternalError!void {
    if (!p.eat(.{ .keyword = kw })) {
        p.addError(
            p.peek(),
            "Expected {s} but got \"{s}\"",
            .{ @tagName(kw), p.peek().text(p.input) },
        );
        return InternalError.UnexpectedToken;
    }
}

/// Look at the current token and advance if it is a keyword that we expect.
/// Throw an error if it doesn't match.
fn expectSymbol(p: *Parser, s: Lexer.Token.Symbol) InternalError!void {
    if (!p.eat(.{ .symbol = s })) {
        p.addError(
            p.peek(),
            "Expected \"{s}\" but got \"{s}\"",
            .{ s.text(), p.peek().text(p.input) },
        );
        return InternalError.UnexpectedToken;
    }
}

/// Allocate memory for a value
pub fn make(p: *Parser, val: anytype) *@TypeOf(val) {
    const ptr = p.alloc.create(@TypeOf(val)) catch oom();
    ptr.* = val;
    return ptr;
}

/// Parse a whole statement, expecting the end after it.
pub fn parse(p: *Parser) ast.Statement {
    const result = p.parseStmt();
    p.expect(.eof) catch {};
    return result;
}

/// Parse a single statement.
/// ```
/// Statement = Select
///           | Insert
///           | Delete
///           | Update
///           | Create
///           | Truncate
///           | Begin
///           | Commit
///           | Rollback
/// ```
fn parseStmt(p: *Parser) ast.Statement {
    const t = p.peek();
    if (t.keyword()) |kw| switch (kw) {
        .select => return p.parseSelect(),
        .insert => return p.parseInsert(),
        .delete => return p.parseDelete(),
        .update => return p.parseUpdate(),
        .create => return p.parseCreate(),
        .truncate => return p.parseTruncate(),
        .begin => return p.parseBegin(),
        .commit => return p.parseCommit(),
        .rollback => return p.parseRollback(),
        else => {},
    };

    p.addError(
        t,
        "Expected a statement but got \"{s}\"",
        .{t.text(p.input)},
    );
    return .err;
}

/// Parse a SELECT statement
/// ```
/// Select = "SELECT" CommaList(Expression) "FROM" DataSourceList ("WHERE" Expression)? ";"
/// ```
fn parseSelect(p: *Parser) ast.Statement {
    p.expectKeyword(.select) catch return .err;
    const columns =
        p.parseCommaList(ast.Expression, parseExpression);
    p.expectKeyword(.from) catch return .err;
    const sources = p.parseDataSourceList() catch return .err;
    const condition = if (p.eat(.{ .keyword = .where }))
        p.make(p.parseExpression())
    else
        null;
    p.expectSymbol(.semi) catch return .err;
    return .{ .select = .{
        .columns = columns,
        .sources = sources,
        .where = condition,
    } };
}

/// Parse a DELETE statement
/// ```
/// Delete = "DELETE" "FROM" Name ("WHERE" Expression)? ";"
/// ```
fn parseDelete(p: *Parser) ast.Statement {
    p.expectKeyword(.delete) catch return .err;
    p.expectKeyword(.from) catch return .err;
    const name = p.parseName() catch return .err;
    const condition = if (p.eat(.{ .keyword = .where }))
        p.make(p.parseExpression())
    else
        null;
    p.expectSymbol(.semi) catch return .err;
    return .{ .delete = .{
        .name = name,
        .where = condition,
    } };
}

/// Parse an UPDATE statement
/// ```
/// Update = "UPDATE" Name "SET" CommaList(SetClause) ("WHERE" Expression)? ";"
/// ```
fn parseUpdate(p: *Parser) ast.Statement {
    p.expectKeyword(.update) catch return .err;
    const name = p.parseName() catch return .err;
    p.expectKeyword(.set) catch return .err;

    const clauses =
        p.parseCommaListErr(
            ast.Statement.Update.SetClause,
            parseSetClause,
        ) catch return .err;

    const condition = if (p.eat(.{ .keyword = .where }))
        p.make(p.parseExpression())
    else
        null;

    p.expectSymbol(.semi) catch return .err;

    return .{ .update = .{
        .name = name,
        .clauses = clauses,
        .where = condition,
    } };
}

/// Parse an SET clause for UPDATE statement
/// ```
/// SetClause = Name "=" Expression
/// ```
fn parseSetClause(p: *Parser) InternalError!ast.Statement.Update.SetClause {
    const column = try p.parseName();
    try p.expectSymbol(.eq);
    const expr = p.make(p.parseExpression());
    return .{
        .column = column,
        .expr = expr,
    };
}

/// Parse a comma-separated list.
/// This is a generic that works for any parser function.
/// ```
/// CommaList(F) = F ("," F)*
/// ```
fn parseCommaList(
    p: *Parser,
    comptime T: type,
    comptime f: fn (p: *Parser) T,
) []T {
    var list: std.ArrayList(T) = .empty;
    list.append(p.alloc, f(p)) catch oom();
    while (p.eat(.{ .symbol = .comma })) {
        list.append(p.alloc, f(p)) catch oom();
    }
    return list.toOwnedSlice(p.alloc) catch oom();
}

/// Parse a comma-separated list for a function that can return an error.
/// This is a generic that works for any parser function.
/// ```
/// CommaList(F) = F ("," F)*
/// ```
fn parseCommaListErr(
    p: *Parser,
    comptime T: type,
    comptime f: fn (p: *Parser) InternalError!T,
) InternalError![]T {
    var list: std.ArrayList(T) = .empty;
    list.append(p.alloc, try f(p)) catch oom();
    while (p.eat(.{ .symbol = .comma })) {
        list.append(p.alloc, try f(p)) catch oom();
    }
    return list.toOwnedSlice(p.alloc) catch oom();
}

/// Parse a data source list. Currently is simply a comma-separated list.
/// ```
/// DataSourceList = DataSource ("," DataSource)*
/// ```
fn parseDataSourceList(p: *Parser) ![]ast.DataSource {
    var exprs: std.ArrayList(ast.DataSource) = .empty;
    exprs.append(p.alloc, try p.parseDataSource()) catch oom();
    while (p.eat(.{ .symbol = .comma })) {
        exprs.append(p.alloc, try p.parseDataSource()) catch oom();
    }
    return exprs.toOwnedSlice(p.alloc);
}

/// Parse a data source. Currently only table names are supported.
/// ```
/// DataSource = Name
/// ```
fn parseDataSource(p: *Parser) !ast.DataSource {
    const name = try p.parseName();
    return .{ .table = .{ .name = name } };
}

/// Parse an INSERT statement. Currently only VALUES form is supported.
/// ```
/// Insert = "INSERT" "INTO" Name ("(" CommaList(Name) ")")?
///          "VALUES" CommaList(ValueList) ";"
/// ```
fn parseInsert(p: *Parser) ast.Statement {
    p.expectKeyword(.insert) catch return .err;
    p.expectKeyword(.into) catch return .err;
    const name = p.parseName() catch return .err;
    const columns: []ast.Name = if (p.eat(.{ .symbol = .lparen })) columns: {
        const columns =
            p.parseCommaListErr(ast.Name, parseName) catch return .err;
        p.expectSymbol(.rparen) catch return .err;
        break :columns columns;
    } else &.{};
    p.expectKeyword(.values) catch return .err;
    const values =
        p.parseCommaListErr(ast.ValueList, parseValueList) catch return .err;
    p.expectSymbol(.semi) catch return .err;
    return .{ .insert_values = .{
        .name = name,
        .columns = columns,
        .values = values,
    } };
}

/// Parse a value list (for VALUES).
/// ```
/// ValueList = "(" CommaList(Expression) ")"
/// ```
fn parseValueList(p: *Parser) !ast.ValueList {
    try p.expectSymbol(.lparen);
    const exprs =
        p.parseCommaList(ast.Expression, parseExpression);
    try p.expectSymbol(.rparen);
    return .{ .columns = exprs };
}

/// Parse a CREATE statement. Currently only CREATE TABLE supported.
/// ```
/// Create = "CREATE" "TABLE" Name "(" CollaList(ColumnDefinition) ")" ";"
/// ```
fn parseCreate(p: *Parser) ast.Statement {
    p.expectKeyword(.create) catch return .err;
    p.expectKeyword(.table) catch return .err;
    const name = p.parseName() catch return .err;
    p.expectSymbol(.lparen) catch return .err;
    const columns =
        p.parseCommaListErr(
            ast.Statement.CreateTable.ColumnDefinition,
            parseColumnDefinition,
        ) catch return .err;
    p.expectSymbol(.rparen) catch return .err;
    p.expectSymbol(.semi) catch return .err;
    return .{ .create_table = .{
        .name = name,
        .columns = columns,
    } };
}

/// Parse a column definition for CREATE TABLE supported.
/// ```
/// ColumnDefinition = Name Type
/// ```
fn parseColumnDefinition(p: *Parser) !ast.Statement.CreateTable.ColumnDefinition {
    const name = try p.parseName();
    const dbtype = try p.parseType();
    return .{ .name = name, .col_type = dbtype };
}

/// Parse a TRUNCATE statement.
/// ```
/// Truncate = "TRUNCATE" Name ";"
/// ```
fn parseTruncate(p: *Parser) ast.Statement {
    p.expectKeyword(.truncate) catch return .err;
    const name = p.parseName() catch return .err;
    p.expectSymbol(.semi) catch return .err;
    return .{ .truncate = .{
        .name = name,
    } };
}

/// Parse a BEGIN statement.
/// ```
/// Begin = "BEGIN" ";"
/// ```
fn parseBegin(p: *Parser) ast.Statement {
    p.expectKeyword(.begin) catch return .err;
    p.expectSymbol(.semi) catch return .err;
    return .begin;
}

/// Parse a COMMIT statement.
/// ```
/// Commit = "COMMIT" ";"
/// ```
fn parseCommit(p: *Parser) ast.Statement {
    p.expectKeyword(.commit) catch return .err;
    p.expectSymbol(.semi) catch return .err;
    return .commit;
}

/// Parse a ROLLBACK statement.
/// ```
/// Rollback = "ROLLBACK" ";"
/// ```
fn parseRollback(p: *Parser) ast.Statement {
    p.expectKeyword(.rollback) catch return .err;
    p.expectSymbol(.semi) catch return .err;
    return .rollback;
}

/// Parse a type name.
/// ```
/// Type = "INT"
///      | "BOOL"
///      | "TEXT"
/// ```
fn parseType(p: *Parser) InternalError!DBType {
    const t = p.peek();
    if (t.keyword()) |kw| switch (kw) {
        .int => {
            p.pos += 1;
            return .int4;
        },
        .bool => {
            p.pos += 1;
            return .bool;
        },
        .text => {
            p.pos += 1;
            return .text;
        },
        else => {},
    };

    p.addError(
        t,
        "Expected a type but got \"{s}\"",
        .{t.text(p.input)},
    );
    return InternalError.UnexpectedToken;
}

/// This parses an expression. Expressions use a Pratt parser
/// to handle precendence properly through binding power.
/// The general (ambiguous) grammar is the following:
///
/// ```
/// Expression = AtomicExpression
///            | PrefixOp Expression
///            | Expression PostfixOp
///            | Expression InfixOp Expression
///            | "(" Expression ")"
/// PrefixOp = "-"
///          | "NOT"
/// PostfixOp = "IS" "NULL"
///           | "IS" "NOT" "NULL"
/// InfixOp = "+" | "-" | "*" | "/"
///         | "=" | "<>"
///         | ">" | "<" | ">=" | "<="
///         | "AND" | "OR"
/// ```
///
/// To make this grammar not ambiguous, precendences are determined
/// by giving each operator "binding power". Prefix and postfix
/// operators have one binding power each, and infix have left and right binding powers.
/// For example, if we have an expression like "A op1 B op2 C", then it is parsed
/// like "(A op1 B) op2 C" if op1 binds stronger to B than op2, so if op1's right BP
/// power is bigger than op2's left BP. Similarly, it is parsed like "A op1 (B op2 C)"
/// if op1's right BP is less than op2's left BP.
///
/// Here are the binding power tables, sorted from strongest to weakest:
///
/// ```
///     Operator   | Left | Right
/// ---------------+------+-------
///  - (unary)     |      |    25
///  *, /          |   23 |    24
///  +, -          |   21 |    22
///  IS (NOT) NULL |   10 |
/// <, >, <=, >=   |    8 |     9
/// =, <>          |    7 |     6
/// NOT            |      |     5
/// AND            |    3 |     4
/// OR             |    1 |     2
/// ```
fn parseExpression(p: *Parser) ast.Expression {
    return p.parseExpressionPratt(0);
}

/// Calculate binding power for a postfix operator
fn postfixBindingPower(t: Lexer.Token.Kind) ?u8 {
    return switch (t) {
        .keyword => |kw| switch (kw) {
            .is => 10,
            else => null,
        },
        else => null,
    };
}

/// Calculate binding power for a prefix operator
fn prefixBindingPower(t: Lexer.Token.Kind) ?u8 {
    return switch (t) {
        .symbol => |s| switch (s) {
            .minus => 25,
            else => null,
        },
        .keyword => |kw| switch (kw) {
            .not => 5,
            else => null,
        },
        else => null,
    };
}

/// Calculate left and right binding powers for an infix operator
fn infixBindingPower(t: Lexer.Token.Kind) ?struct { l: u8, r: u8 } {
    return switch (t) {
        .symbol => |s| switch (s) {
            .eq, .ne => .{ .l = 7, .r = 6 },
            .lt, .gt, .le, .ge => .{ .l = 8, .r = 9 },
            .plus, .minus => .{ .l = 21, .r = 22 },
            .star, .slash => .{ .l = 23, .r = 24 },
            else => null,
        },
        .keyword => |kw| switch (kw) {
            .@"or" => .{ .l = 1, .r = 2 },
            .@"and" => .{ .l = 3, .r = 4 },
            else => null,
        },
        else => null,
    };
}

/// Convert token into a binary operator
fn infixOp(t: Lexer.Token.Kind) ?ast.Expression.Binary.Op {
    return switch (t) {
        .symbol => |s| switch (s) {
            .plus => .add,
            .minus => .sub,
            .star => .mul,
            .slash => .div,
            .eq => .eq,
            .ne => .ne,
            .lt => .lt,
            .gt => .gt,
            .le => .le,
            .ge => .ge,
            else => null,
        },
        .keyword => |kw| switch (kw) {
            .@"or" => .@"or",
            .@"and" => .@"and",
            else => null,
        },
        else => null,
    };
}

/// Actual recursive Pratt parser for expressions
fn parseExpressionPratt(p: *Parser, min_bp: u8) ast.Expression {
    const t = p.peek();
    var lhs = switch (t.kind) {
        .symbol => |s| switch (s) {
            .lparen => lhs: {
                p.expectSymbol(.lparen) catch unreachable;
                const expr = p.parseExpressionPratt(0);
                p.expectSymbol(.rparen) catch return .err;
                break :lhs expr;
            },
            .minus => lhs: {
                p.expectSymbol(.minus) catch unreachable;
                const bp = prefixBindingPower(t.kind).?;
                const expr = p.make(p.parseExpressionPratt(bp));
                break :lhs ast.Expression{ .unary = .{
                    .op = .neg,
                    .expr = expr,
                } };
            },
            else => {
                p.addError(t, "Expected expression but got \"{s}\"", .{s.text()});
                return .err;
            },
        },
        else => p.parseAtomicExpression(),
    };

    while (true) {
        const op_token = p.peek();

        if (postfixBindingPower(op_token.kind)) |bp| {
            if (bp < min_bp)
                break;
            p.advance();

            if (op_token.matches(.{ .keyword = .is })) {
                const negate = p.eat(.{ .keyword = .not });
                p.expectKeyword(.null) catch return .err;

                const op: ast.Expression.Unary.Op = if (negate) .not_null else .null;
                const new = ast.Expression{ .unary = .{
                    .op = op,
                    .expr = p.make(lhs),
                } };
                lhs = new;
                continue;
            } else unreachable;
        }

        if (infixBindingPower(op_token.kind)) |bp| {
            if (bp.l < min_bp)
                break;

            p.advance();

            const lhs_expr = p.make(lhs);
            const rhs_expr = p.make(p.parseExpressionPratt(bp.r));

            const new = ast.Expression{ .binary = .{
                .op = infixOp(op_token.kind).?,
                .left = lhs_expr,
                .right = rhs_expr,
            } };
            lhs = new;
            continue;
        }

        break;
    }
    return lhs;
}

/// Parse an atomic expression. Currently only numbers and columns are supported.
/// ```
/// AtomicExpression = NUMBER
///                  | STRING
///                  | "true"
///                  | "false"
///                  | Name
/// ```
fn parseAtomicExpression(p: *Parser) ast.Expression {
    const t = p.peek();
    switch (t.kind) {
        .keyword => |kw| switch (kw) {
            .true => {
                p.pos += 1;
                return .{ .bool = true };
            },
            .false => {
                p.pos += 1;
                return .{ .bool = false };
            },
            .null => {
                p.pos += 1;
                return .null;
            },
            else => {
                p.addError(
                    t,
                    "Expected an expression but got \"{s}\"",
                    .{t.text(p.input)},
                );
                return .err;
            },
        },
        .num => {
            const x =
                std.fmt.parseInt(i64, t.text(p.input), 10) catch {
                    p.addError(t, "Invalid number \"{s}\"", .{t.text(p.input)});
                    return .err;
                };
            p.pos += 1;
            return .{ .integer = x };
        },
        .str => {
            const raw = t.text(p.input);
            var arr = std.ArrayList(u8).initCapacity(p.alloc, raw.len + 1) catch oom();
            arr.appendAssumeCapacity(0); // Mandatory 0 start
            var i: usize = 0;
            while (i < raw.len) {
                if (raw[i] == '\\') {
                    const c: u8 = switch (raw[i + 1]) {
                        'n' => '\n',
                        't' => '\t',
                        'r' => '\r',
                        '\'' => '\'',
                        '"' => '"',
                        '\\' => '\\',
                        else => {
                            p.addError(t, "Invalid escale sequence \"\\{}\"", .{raw[i + 1]});
                            return .err;
                        },
                    };
                    arr.appendAssumeCapacity(c);
                    i += 2;
                } else {
                    arr.appendAssumeCapacity(raw[i]);
                    i += 1;
                }
            }
            p.pos += 1;
            return .{ .string = .{ .raw = arr.toOwnedSlice(p.alloc) catch oom() } };
        },
        .id => {
            return .{ .variable = p.parseName() catch return .err };
        },
        else => {
            p.addError(
                t,
                "Expected an expression but got \"{s}\"",
                .{t.text(p.input)},
            );
            return .err;
        },
    }
}

/// Parse a name. This is simply an identifier
/// ```
/// Name = IDENTIFIER
/// ```
fn parseName(p: *Parser) !ast.Name {
    const t = p.peek();
    if (t.kind == .id) {
        p.advance();
        return t.text(p.input);
    } else {
        p.addError(
            t,
            "Expected a name but got \"{s}\"",
            .{t.text(p.input)},
        );
        return InternalError.UnexpectedToken;
    }
}
