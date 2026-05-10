//! Lexer for SQL

const std = @import("std");
const oom = @import("common").oom;

const Lexer = @This();

alloc: std.mem.Allocator, // Allocator for output
input: []const u8, // Input text
pos: usize, // Current position in the input
tokens: std.MultiArrayList(Token), // Output tokens

/// Initialize the lexer from input text
pub fn init(alloc: std.mem.Allocator, input: []const u8) Lexer {
    return .{
        .alloc = alloc,
        .input = input,
        .pos = 0,
        .tokens = .empty,
    };
}

/// Get the final tokens array from the lexer
pub fn finalize(self: *Lexer) std.MultiArrayList(Token) {
    return self.tokens;
}

/// A single token in the lexed SQL
pub const Token = struct {
    kind: Kind, // Type of the token
    start: u32, // Position of the token start in the input
    end: u32, // Position of the token end in the input

    pub const Keyword = enum(u8) {
        select,
        from,
        as,
        join,
        on,
        inner,
        left,
        right,
        full,
        where,
        insert,
        into,
        delete,
        update,
        set,
        values,
        create,
        table,
        truncate,
        drop,
        begin,
        commit,
        rollback,
        int,
        serial,
        boolean,
        text,
        @"and",
        @"or",
        not,
        true,
        false,
        null,
        is,
    };

    pub const Symbol = enum(u8) {
        lparen,
        rparen,
        semi,
        dot,
        comma,
        eq,
        ne,
        lt,
        gt,
        le,
        ge,
        plus,
        minus,
        star,
        slash,

        pub fn text(s: Symbol) []const u8 {
            return SymbolReverseMap.get(s);
        }
    };

    pub const Kind = union(enum) {
        keyword: Keyword,
        symbol: Symbol,
        id: void,
        num: void,
        str: void,
        eof: void,
    };

    /// Get the text corresponding to the token
    pub fn text(t: Token, input: []const u8) []const u8 {
        return input[t.start..t.end];
    }

    /// Check if the token matches expected token kind
    pub fn matches(t: Token, k: Kind) bool {
        return std.meta.eql(t.kind, k);
    }

    /// Get the keyword if the token is a keyword
    pub fn keyword(t: Token) ?Keyword {
        switch (t.kind) {
            .keyword => |kw| return kw,
            else => return null,
        }
    }
};

/// Comptime-generated string map for all keywords.
/// Lookups ignore case, making it an efficient way to check if a string is a keyword.
const KeywordMap = std.StaticStringMapWithEql(
    Token.Keyword,
    std.static_string_map.eqlAsciiIgnoreCase,
).initComptime(block: {
    const KeywordEntry = struct { []const u8, Token.Keyword };
    const count = std.enums.values(Token.Keyword).len;
    // Make an array of keyword entries, each containing its text and enum value
    var result: [count]KeywordEntry = undefined;
    // Go through all possible keywords and fill the array
    for (std.enums.values(Token.Keyword), 0..) |kw, i| {
        result[i] = .{ @tagName(kw), kw };
    }
    // Build a string map from it
    break :block result;
});

/// Comptime-generated string map for all symbols.
/// This is an efficient way to find a symbol enum from text.
const SymbolMap = std.StaticStringMap(Token.Symbol).initComptime(.{
    .{ "(", Token.Symbol.lparen },
    .{ ")", Token.Symbol.rparen },
    .{ ";", Token.Symbol.semi },
    .{ ".", Token.Symbol.dot },
    .{ ",", Token.Symbol.comma },
    .{ "=", Token.Symbol.eq },
    .{ "<>", Token.Symbol.ne },
    .{ "<", Token.Symbol.lt },
    .{ ">", Token.Symbol.gt },
    .{ "<=", Token.Symbol.le },
    .{ ">=", Token.Symbol.ge },
    .{ "+", Token.Symbol.plus },
    .{ "-", Token.Symbol.minus },
    .{ "*", Token.Symbol.star },
    .{ "/", Token.Symbol.slash },
});

/// Comptime generated reverse string map for all the symbols.
/// Attaches a text to each symbol.
const SymbolReverseMap: std.EnumArray(Token.Symbol, []const u8) = block: {
    var result: std.EnumArray(Token.Symbol, []const u8) = .initUndefined();
    for (SymbolMap.keys(), SymbolMap.values()) |k, v| {
        result.set(v, k);
    }
    break :block result;
};

/// Get the current character (or null if the string has ended).
fn curr(self: *const Lexer) ?u8 {
    if (self.pos < self.input.len)
        return self.input[self.pos]
    else
        return null;
}

/// Lex a single word (keyword or identifier).
/// The word must match regex [a-zA-Z_][a-zA-Z0-9_]*
fn lexWord(self: *Lexer) Token {
    const start = self.pos;
    const first = self.curr().?;
    // This should only be called if the first character is already [a-zA-Z]
    std.debug.assert(std.ascii.isAlphabetic(first));

    // Advance until the characters stop matching [a-zA-Z0-9_] (or the input ends).
    while (self.curr()) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_')
            self.pos += 1
        else
            break;
    }
    // This is the end of the word
    const end = self.pos;

    const text = self.input[start..end];

    // Check if it's a keyword
    if (KeywordMap.get(text)) |kw| {
        return .{
            .kind = .{ .keyword = kw },
            .start = @intCast(start),
            .end = @intCast(end),
        };
    } else {
        return .{
            .kind = .id,
            .start = @intCast(start),
            .end = @intCast(end),
        };
    }
}

/// Lex a single number literal. Only the integers are currently supported.
/// The number must match a regex [0-9]+
fn lexNum(self: *Lexer) Token {
    const start = self.pos;
    const first = self.curr().?;
    // This should only be called if the first character is already [0-9]
    std.debug.assert(std.ascii.isDigit(first));

    // Advance until the characters stop matching [0-9_] (or the input ends).
    while (self.curr()) |c| {
        if (std.ascii.isDigit(c))
            self.pos += 1
        else
            break;
    }
    // This is the end of the number
    const end = self.pos;

    return .{
        .kind = .num,
        .start = @intCast(start),
        .end = @intCast(end),
    };
}

/// Lex a single string literal.
/// The number must match a regex '([^\]|\.)*'
fn lexStr(self: *Lexer) ?Token {
    const first = self.curr().?;
    // This should only be called if the first character is already '
    std.debug.assert(first == '\'');
    self.pos += 1;
    const start = self.pos;

    // Advance until we get to ' (or the input ends).
    // Also handle escape sequences.
    while (self.curr()) |c| {
        if (c == '\'') // End of the string
            break
        else if (c == '\\') // Escape sequence
            self.pos += 2
        else // Something else
            self.pos += 1;
    }
    // This is the end of the string
    const end = self.pos;
    // The string must end with '
    const last = self.curr();
    if (last != '\'') {
        return null;
    }
    self.pos += 1;

    return .{
        .kind = .str,
        .start = @intCast(start),
        .end = @intCast(end),
    };
}

/// Lexer errors have a position attached to them
pub const Error = struct {
    kind: Kind,
    pos: u32,

    pub const Kind = enum {
        unknown_character,
        unclosed_string,
    };
};

/// Fully lex the input string and fill the output array.
/// Return an error if anything goes wrong.
pub fn lex(self: *Lexer) ?Error {
    // Go until the end of the string
    while (self.curr()) |c| {
        const start = self.pos;
        // This is ensures lexer advanced at least by 1 in this iteration,
        // so we don't get stuck in an infinite loop.
        defer std.debug.assert(self.pos > start);

        if (std.ascii.isWhitespace(c))
            // Skip whitespace
            self.pos += 1
        else if (c == '\'')
            // Lex a string literal if the first character is '
            self.tokens.append(
                self.alloc,
                self.lexStr() orelse
                    return Error{
                        .kind = .unclosed_string,
                        .pos = @intCast(self.pos),
                    },
            ) catch oom()
        else if (std.ascii.isAlphabetic(c) or c == '_')
            // Lex a word if the first character is [a-zA-Z_]
            self.tokens.append(self.alloc, self.lexWord()) catch oom()
        else if (std.ascii.isDigit(c))
            // Lex a number if the first character is [0-9]
            self.tokens.append(self.alloc, self.lexNum()) catch oom()
        else if (SymbolMap.getLongestPrefix(self.input[self.pos..])) |kv| {
            // If we found this to be a symbol, lex a symbol
            // The longest possible symbol gets matched since getLongestPrefix is used.
            self.tokens.append(self.alloc, .{
                .kind = .{ .symbol = kv.value },
                .start = @intCast(self.pos),
                .end = @intCast(self.pos + kv.key.len),
            }) catch oom();
            self.pos += kv.key.len;
        } else {
            // Nothing matches, this is an error.
            defer self.pos += 1;
            return Error{
                .kind = .unknown_character,
                .pos = @intCast(self.pos),
            };
        }
    }
    // We reached the end without errors.
    return null;
}
