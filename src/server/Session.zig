//! Session state, stores all the global state necessary to execute statements.

const std = @import("std");

const common = @import("common");
const storage = @import("storage.zig");
const heap = @import("heap.zig");
const ids = common.ids;
const catalog = @import("catalog.zig");
const transaction = @import("transaction.zig");
const planner = @import("planner.zig");
const lock = @import("lock.zig");
const Executor = @import("executor/Executor.zig");

const Lexer = @import("sql/Lexer.zig");
const Parser = @import("sql/Parser.zig");
const Context = @import("executor/Context.zig");
const Plan = planner.Plan;
const Planner = planner.Planner;

const Session = @This();

/// Global allocator
gpa: std.mem.Allocator,
/// Cache of catalog tables.
catalog_cache: *catalog.Cache,
/// Id of the current database.
db_id: ids.DatabaseId,
/// Id of the current transaction.
current_tid: transaction.Id,
/// Id of the executor thread.
thread_id: std.Thread.Id,
/// Status of an explicit transaction.
explicit_transaction: transaction.ExplicitStatus = .inactive,
/// Shared state, this is memory shared between all threads.
shared: Shared,

pub const Shared = struct {
    /// Cache of disk pages
    storage_cache: *storage.Cache,
    /// Log of transaction statuses
    transaction_log: *transaction.Log,
    /// Manager for various locks
    lock_manager: *lock.Manager,
};

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

    const catalog_snapshot = transaction.Snapshot.create(
        s.shared.transaction_log,
        s.current_tid,
    );
    s.catalog_cache.rebuild(&catalog_snapshot) catch |e| {
        try sender.log(
            arena.allocator(),
            "Couldn't build catalog cache: {}\n",
            .{e},
        );
        try sender.send(.err);
        return;
    };

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
        errdefer if (s.explicit_transaction == .inactive) {
            // If something went wrong in an implicit transaction, abort it
            s.shared.transaction_log.set(s.current_tid, .aborted) catch {};
        } else {
            // If something went wrong in an explicit transaction, mark it as broken
            s.explicit_transaction = .broken;
        };

        // Take a snapshot at the start of the command
        const snapshot = transaction.Snapshot.create(
            s.shared.transaction_log,
            s.current_tid,
        );

        // Form the execution context
        var cxt = Context{
            .alloc = arena.allocator(),
            .s = s,
            .snapshot = &snapshot,
            .sender = sender,
        };
        // Execute the query
        Executor.execute(plan, &cxt) catch |err| {
            if (err != Executor.Error.ExecutionError) {
                try sender.log(
                    arena.allocator(),
                    "ERROR: {}",
                    .{err},
                );
            }
            try sender.send(.err);
            if (s.explicit_transaction == .active)
                s.explicit_transaction = .broken;
            return;
        };

        if (s.explicit_transaction == .inactive) {
            // Commit the transaction at the end, if it was implicit
            try s.shared.transaction_log.set(s.current_tid, .committed);
            s.current_tid = .virtual;
            // Unlock all locks
            try s.shared.lock_manager.unlockAll(s.thread_id);
        }

        // Send the success message
        try sender.send(.success);
    }
}
