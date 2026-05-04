//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
pub const common = @import("common");
pub const storage = @import("storage.zig");
const heap = @import("heap.zig");
pub const ids = common.ids;
pub const catalog = @import("catalog.zig");
pub const transaction = @import("transaction.zig");
const planner = @import("planner.zig");
const Executor = @import("executor/Executor.zig");
const Context = @import("executor/Context.zig");

const Lexer = @import("sql/Lexer.zig");
const Parser = @import("sql/Parser.zig");
const Plan = planner.Plan;
const Planner = planner.Planner;

pub const Error = error{
    LexerError,
    ParserError,
    PlannerError,
    ExecutorError,
};

/// Execute a single statement
pub fn execute_stmt(
    io: std.Io,
    gpa: std.mem.Allocator,
    storage_cache: *storage.Cache,
    catalog_cache: *catalog.Cache,
    transaction_log: *transaction.Log,
    query: []const u8,
) !void {
    // Temporary arena for this statement
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    // Initialize stderr and stdout writers
    var bufferStderr: [512]u8 = undefined;
    var bufferStdout: [512]u8 = undefined;
    const stderr_locked = try io.lockStderr(&bufferStderr, null);
    defer io.unlockStderr();
    var stderr_writer = stderr_locked.file_writer;
    var stdout_writer = std.Io.File.stdout().writer(io, &bufferStdout);
    const stderr = &stderr_writer.interface;
    const stdout = &stdout_writer.interface;
    defer stderr.flush() catch unreachable;
    defer stdout.flush() catch unreachable;

    // Lex the query
    var parser = Parser.init(arena.allocator());
    if (parser.lex(query)) |err| {
        try stderr.print("Error: {}\n", .{err});
        return Error.LexerError;
    }

    // Parse the query
    const stmt = parser.parse();
    for (parser.errors.items) |err|
        try stderr.print("{s}\n", .{err});
    if (parser.errors.items.len > 0)
        return Error.ParserError;

    // {
    //     const formatted = std.json.fmt(
    //         stmt,
    //         .{ .whitespace = .indent_2 },
    //     );
    //     std.debug.print("{f}\n", .{formatted});
    // }

    // Plan the parsed query
    var pl = Planner.init(arena.allocator(), catalog_cache);
    const plan = pl.plan(stmt) catch {
        for (pl.errors.items) |err|
            try stderr.print("{s}\n", .{err});
        return Error.PlannerError;
    };

    // std.debug.print("Successfully planned\n", .{});
    // const formatted = std.json.fmt(
    //     plan,
    //     .{ .whitespace = .indent_2 },
    // );
    // std.debug.print("{f}\n", .{formatted});

    {
        const tid = transaction_log.next();
        errdefer transaction_log.set(tid, .aborted) catch {};

        const snapshot = transaction.Snapshot.create(
            transaction_log,
            tid,
        );

        // Form the execution context
        var cxt = Context{
            .alloc = arena.allocator(),
            .catalog_cache = catalog_cache,
            .storage_cache = storage_cache,
            .transaction_log = transaction_log,
            .db_id = 1,
            .tid = tid,
            .snapshot = &snapshot,
            .output = stdout,
        };
        // Execute the query
        Executor.execute(plan, &cxt) catch |err| {
            try stderr.print("Error: {}\n", .{err});
            return Error.ExecutorError;
        };

        // Print output tuples, if any
        for (cxt.data_output.items) |tuple| {
            try stdout.print("{f}\n", .{tuple});
        }

        try transaction_log.set(tid, .committed);
    }
}
