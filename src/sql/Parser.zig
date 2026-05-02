//! This is a recursive descent parser for SQL
//! It is not particularly optimized and the errors aren't great,
//! so it should probably be reworked in the future.

const std = @import("std");
const Lexer = @import("Lexer.zig");
const ast = @import("ast.zig");
const DBType = @import("../data/types.zig").DBType;
const oom = @import("../utils.zig").oom;

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
///           | Create
///           | Truncate
/// ```
fn parseStmt(p: *Parser) ast.Statement {
    const t = p.peek();
    if (t.keyword()) |kw| switch (kw) {
        .select => return p.parseSelect(),
        .insert => return p.parseInsert(),
        .create => return p.parseCreate(),
        .truncate => return p.parseTruncate(),
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
/// Select = "SELECT" CommaList(Expression) FROM DataSourceList ";"
/// ```
fn parseSelect(p: *Parser) ast.Statement {
    p.expectKeyword(.select) catch return .err;
    const columns =
        p.parseCommaListErr(ast.Expression, parseExpression) catch return .err;
    p.expectKeyword(.from) catch return .err;
    const sources = p.parseDataSourceList() catch return .err;
    p.expectSymbol(.semi) catch return .err;
    return .{ .select = .{
        .columns = columns,
        .sources = sources,
    } };
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
) std.ArrayList(T) {
    var list: std.ArrayList(T) = .empty;
    list.append(p.alloc, f(p)) catch oom();
    while (p.eat(.{ .symbol = .comma })) {
        list.append(p.alloc, f(p)) catch oom();
    }
    return list;
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
) InternalError!std.ArrayList(T) {
    var list: std.ArrayList(T) = .empty;
    list.append(p.alloc, try f(p)) catch oom();
    while (p.eat(.{ .symbol = .comma })) {
        list.append(p.alloc, try f(p)) catch oom();
    }
    return list;
}

/// Parse a data source list. Currently is simply a comma-separated list.
/// ```
/// DataSourceList = DataSource ("," DataSource)*
/// ```
fn parseDataSourceList(p: *Parser) !std.ArrayList(ast.DataSource) {
    var exprs: std.ArrayList(ast.DataSource) = .empty;
    exprs.append(p.alloc, try p.parseDataSource()) catch oom();
    while (p.eat(.{ .symbol = .comma })) {
        exprs.append(p.alloc, try p.parseDataSource()) catch oom();
    }
    return exprs;
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
    const columns: std.ArrayList(ast.Name) = if (p.eat(.{ .symbol = .lparen })) columns: {
        const columns =
            p.parseCommaListErr(ast.Name, parseName) catch return .err;
        p.expectSymbol(.rparen) catch return .err;
        break :columns columns;
    } else .empty;
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
        try p.parseCommaListErr(ast.Expression, parseExpression);
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

/// Parse an expression. Currently only numbers and columns are supported.
/// ```
/// Expression = NUMBER
///            | Name
/// ```
fn parseExpression(p: *Parser) !ast.Expression {
    const t = p.peek();
    switch (t.kind) {
        .num => {
            const x =
                std.fmt.parseInt(i64, t.text(p.input), 10) catch {
                    p.addError(t, "Invalid number \"{s}\"", .{t.text(p.input)});
                    return .err;
                };
            p.pos += 1;
            return .{ .integer = x };
        },
        .id => {
            return .{ .variable = try p.parseName() };
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
