const std = @import("std");

const common = @import("common");
const storage = @import("storage.zig");
const heap = @import("heap.zig");
const ids = common.ids;
const catalog = @import("catalog.zig");
const transaction = @import("transaction.zig");
const planner = @import("planner.zig");
const Executor = @import("executor/Executor.zig");

const Lexer = @import("sql/Lexer.zig");
const Parser = @import("sql/Parser.zig");
const Context = @import("executor/Context.zig");
const Plan = planner.Plan;
const Planner = planner.Planner;

const Session = @This();

gpa: std.mem.Allocator,
storage_cache: *storage.Cache,
catalog_cache: *catalog.Cache,
transaction_log: *transaction.Log,

/// Execute a single statement
pub fn execute_stmt(
    s: *Session,
    query: []const u8,
    sender: common.network.Message.Sender,
) !void {
    // Temporary arena for this statement
    var arena = std.heap.ArenaAllocator.init(s.gpa);
    defer arena.deinit();

    std.debug.print("{s}\n", .{query});

    // Lex the query
    var parser = Parser.init(arena.allocator());
    if (parser.lex(query)) |err| {
        try sender.log(
            arena.allocator(),
            "ERROR: {}",
            .{err},
        );
        try sender.send(.err);
        return;
    }

    // Parse the query
    const stmt = parser.parse();
    for (parser.errors.items) |err| {
        try sender.log(
            arena.allocator(),
            "ERROR: {s}",
            .{err},
        );
    }
    if (parser.errors.items.len > 0) {
        try sender.send(.err);
        return;
    }

    // {
    //     const formatted = std.json.fmt(
    //         stmt,
    //         .{ .whitespace = .indent_2 },
    //     );
    //     std.debug.print("{f}\n", .{formatted});
    // }

    // Plan the parsed query
    var pl = Planner.init(arena.allocator(), s.catalog_cache);
    const plan = pl.plan(stmt) catch {
        for (pl.errors.items) |err| {
            try sender.log(
                arena.allocator(),
                "ERROR: {s}",
                .{err},
            );
        }
        try sender.send(.err);
        return;
    };

    // std.debug.print("Successfully planned\n", .{});
    // const formatted = std.json.fmt(
    //     plan,
    //     .{ .whitespace = .indent_2 },
    // );
    // std.debug.print("{f}\n", .{formatted});

    {
        const tid = s.transaction_log.next();
        errdefer s.transaction_log.set(tid, .aborted) catch {};

        const snapshot = transaction.Snapshot.create(
            s.transaction_log,
            tid,
        );

        // Form the execution context
        var cxt = Context{
            .alloc = arena.allocator(),
            .catalog_cache = s.catalog_cache,
            .storage_cache = s.storage_cache,
            .transaction_log = s.transaction_log,
            .db_id = 1,
            .tid = tid,
            .snapshot = &snapshot,
            .sender = sender,
        };
        // Execute the query
        Executor.execute(plan, &cxt) catch |err| {
            try sender.log(
                arena.allocator(),
                "ERROR: {}",
                .{err},
            );
            try sender.send(.err);
            return;
        };

        try s.transaction_log.set(tid, .committed);

        try sender.send(.success);
    }
}
