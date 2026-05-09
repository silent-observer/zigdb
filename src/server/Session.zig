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
const VariablesCache = @import("VariablesCache.zig");
const Logger = @import("Logger.zig");

const Lexer = @import("sql/Lexer.zig");
const Parser = @import("sql/Parser.zig");
const Context = @import("executor/Context.zig");
const Plan = planner.Plan;
const Planner = planner.Planner;

const Session = @This();

/// We have a thread-local global session instance
threadlocal var session: ?Session = null;

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
/// Message sender for client connection.
sender: common.network.Message.Sender, // Message sender
/// Shared state, this is memory shared between all threads.
shared: Shared,

pub const Shared = struct {
    /// Cache of disk pages
    storage_cache: *storage.Cache,
    /// Log of transaction statuses
    transaction_log: *transaction.Log,
    /// Manager for various locks
    lock_manager: *lock.Manager,
    /// Cache of various global variables
    variables_cache: *VariablesCache,
    /// Shared part of the logger
    logger: *Logger.Shared,
};

pub fn register(s: Session) void {
    session = s;
}

pub fn get() *Session {
    return &session.?;
}

/// Execute a single statement
pub fn executeStmt(query: []const u8) !void {
    const s = get();
    // Temporary arena for this statement
    var arena = std.heap.ArenaAllocator.init(s.gpa);
    defer arena.deinit();

    Logger.log("Statement: {s}\n", .{query});

    const catalog_snapshot = try transaction.Snapshot.create(
        s.shared.transaction_log,
        s.current_tid,
        arena.allocator(),
    );
    s.catalog_cache.rebuild(&catalog_snapshot) catch |e| {
        Logger.err("Couldn't build catalog cache: {}\n", .{e});
        try s.sender.send(.err);
        return;
    };

    // Lex the query
    var parser = Parser.init(arena.allocator());
    if (parser.lex(query)) |e| {
        Logger.err("{}", .{e});
        try s.sender.send(.err);
        return;
    }

    // Parse the query
    const stmt = parser.parse();
    for (parser.errors.items) |e| {
        Logger.err("{s}", .{e});
    }
    if (parser.errors.items.len > 0) {
        try s.sender.send(.err);
        return;
    }

    Logger.printPayload(.log, "AST", .{}, stmt);

    // Plan the parsed query
    var pl = Planner.init(arena.allocator(), s.catalog_cache);
    const plan = pl.plan(stmt) catch {
        for (pl.errors.items) |e| {
            Logger.log("{s}", .{e});
        }
        try s.sender.send(.err);
        return;
    };

    Logger.printPayload(.log, "Plan", .{}, plan);

    {
        errdefer if (s.explicit_transaction == .inactive) {
            // If something went wrong in an implicit transaction, abort it
            s.shared.transaction_log.endTransaction(s.current_tid, .aborted) catch {};
            s.current_tid = .virtual;
            s.shared.lock_manager.unlockAll(s.thread_id) catch {};
        } else {
            // If something went wrong in an explicit transaction, mark it as broken
            s.explicit_transaction = .broken;
        };

        // Take a snapshot at the start of the command
        const snapshot = try transaction.Snapshot.create(
            s.shared.transaction_log,
            s.current_tid,
            arena.allocator(),
        );

        // Form the execution context
        var cxt = Context{
            .alloc = arena.allocator(),
            .snapshot = &snapshot,
        };
        // Execute the query
        const message = Executor.execute(plan, &cxt) catch |e| {
            if (e != Executor.Error.ExecutionError) {
                Logger.err("{}", .{e});
            }
            try s.sender.send(.err);
            if (s.explicit_transaction == .active)
                s.explicit_transaction = .broken;
            return;
        };

        if (s.explicit_transaction == .inactive) {
            // Commit the transaction at the end, if it was implicit
            try s.shared.transaction_log.endTransaction(s.current_tid, .committed);
            s.current_tid = .virtual;
            // Unlock all locks
            try s.shared.lock_manager.unlockAll(s.thread_id);
        }

        // Flush data to disk if we can
        try s.shared.storage_cache.flush(false);

        // Send the success message
        try s.sender.send(.{ .success = message });
    }
}
