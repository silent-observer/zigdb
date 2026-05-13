const std = @import("std");
const common = @import("common");

/// Fixed function ids of built-in functions.
pub const FunctionId = enum {
    generate_series,
    upper,
    lower,
    concat,
    len,
    ltrim,
    rtrim,
    trim,
    substring,
};

/// Comptime-generated string map for all function names.
/// Lookups ignore case, making it an efficient way to check if a string is a keyword.
pub const function_map = std.StaticStringMapWithEql(
    FunctionId,
    std.static_string_map.eqlAsciiIgnoreCase,
).initComptime(block: {
    const KeywordEntry = struct { []const u8, FunctionId };
    const count = std.enums.values(FunctionId).len;
    // Make an array of keyword entries, each containing its text and enum value
    var result: [count]KeywordEntry = undefined;
    // Go through all possible keywords and fill the array
    for (std.enums.values(FunctionId), 0..) |id, i| {
        result[i] = .{ @tagName(id), id };
    }
    // Build a string map from it
    break :block result;
});

pub fn evalScalarFunction(id: FunctionId, inputs: []common.Value, alloc: std.mem.Allocator) !common.Value {
    switch (id) {
        .upper => {
            std.debug.assert(inputs.len == 1);
            std.debug.assert(inputs[0] == .text);
            return .{ .text = .makeRaw(std.ascii.allocUpperString(
                alloc,
                inputs[0].text.text(),
            ) catch common.oom()) };
        },
        .lower => {
            std.debug.assert(inputs.len == 1);
            std.debug.assert(inputs[0] == .text);
            return .{ .text = .makeRaw(std.ascii.allocLowerString(
                alloc,
                inputs[0].text.text(),
            ) catch common.oom()) };
        },
        .concat => {
            std.debug.assert(inputs.len == 2);
            std.debug.assert(inputs[0] == .text);
            std.debug.assert(inputs[1] == .text);
            return .{ .text = .makeRaw(std.mem.concat(
                alloc,
                u8,
                &.{ inputs[0].text.text(), inputs[1].text.text() },
            ) catch common.oom()) };
        },
        .len => {
            std.debug.assert(inputs.len == 1);
            std.debug.assert(inputs[0] == .text);
            return .{ .int = @intCast(inputs[0].text.len()) };
        },
        .ltrim => {
            std.debug.assert(inputs.len == 1);
            std.debug.assert(inputs[0] == .text);
            return .{ .text = .makeRaw(std.mem.trimStart(
                u8,
                inputs[0].text.text(),
                " ",
            )) };
        },
        .rtrim => {
            std.debug.assert(inputs.len == 1);
            std.debug.assert(inputs[0] == .text);
            return .{ .text = .makeRaw(std.mem.trimEnd(
                u8,
                inputs[0].text.text(),
                " ",
            )) };
        },
        .trim => {
            std.debug.assert(inputs.len == 1);
            std.debug.assert(inputs[0] == .text);
            return .{ .text = .makeRaw(std.mem.trim(
                u8,
                inputs[0].text.text(),
                " ",
            )) };
        },
        .substring => {
            std.debug.assert(inputs.len == 3);
            std.debug.assert(inputs[0] == .text);
            std.debug.assert(inputs[1] == .int);
            std.debug.assert(inputs[2] == .int);
            const t = inputs[0].text.text();
            const s: usize = @intCast(inputs[1].int);
            const e = s + @as(usize, @intCast(inputs[2].int));
            return .{ .text = .makeRaw(t[s..e]) };
        },
        else => unreachable,
    }
}

const GenerateSeriesState = struct {
    current: i64,
    end: i64,
    step: i64,
};

pub fn initSetReturningFunction(
    id: FunctionId,
    inputs: []common.Value,
    alloc: std.mem.Allocator,
) !*anyopaque {
    switch (id) {
        .generate_series => {
            std.debug.assert(inputs.len == 2 or inputs.len == 3);
            std.debug.assert(inputs[0] == .int);
            std.debug.assert(inputs[1] == .int);
            if (inputs.len == 3)
                std.debug.assert(inputs[2] == .int);

            const state = alloc.create(GenerateSeriesState) catch common.oom();
            state.* = .{
                .current = inputs[0].int,
                .end = inputs[1].int,
                .step = if (inputs.len == 3) inputs[2].int else 1,
            };
            return state;
        },
        else => unreachable,
    }
}

pub fn deinitSetReturningFunction(
    id: FunctionId,
    state: *anyopaque,
    alloc: std.mem.Allocator,
) void {
    switch (id) {
        .generate_series => {
            const s: *GenerateSeriesState = @ptrCast(state);
            alloc.destroy(s);
        },
        else => unreachable,
    }
}

pub fn execSetReturningFunction(
    id: FunctionId,
    state: *anyopaque,
    alloc: std.mem.Allocator,
) !?common.Value {
    _ = alloc;
    switch (id) {
        .generate_series => {
            const s: *GenerateSeriesState = @ptrCast(state);
            const result = s.current;
            if (result < s.end) {
                s.current += s.step;
                return .{ .int = result };
            } else return null;
        },
        else => unreachable,
    }
}
