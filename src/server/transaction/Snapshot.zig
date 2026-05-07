//! This represents a snapshot of a state of a database at some point in time.
//! The basic principle is to remember the first "future" transaction ID, to
//! automatically consider transactions uncompleted if they are in the future,
//! and to keep a list of transactions active at the time of the snapshot.

const std = @import("std");
const transaction = @import("transaction.zig");
const TransactionLog = @import("TransactionLog.zig");
const ids = @import("common").ids;

const Snapshot = @This();

/// Transaction log for looking up transactions.
log: *TransactionLog,
/// The earliest transaction that is still active.
/// Everything starting before this is surely already done.
xmin: ids.RealTransactionId,
/// The earliest transaction that hasn't yet started.
/// Everything starting from this is surely not visible yet.
xmax: ids.RealTransactionId,
/// List of all transactions active at the time of the snapshot (in sorted order)
active_transactions: []ids.RealTransactionId,
/// ID of the current transaction. Our own actions are always visible.
my_tid: transaction.Id,

/// Create a new snapshot
pub fn create(
    log: *TransactionLog,
    my_tid: transaction.Id,
    alloc: std.mem.Allocator,
) !Snapshot {
    // xmax has to be captured before the list of transactions, to avoid
    // possibly missing some new transactions started between the two statements.
    const xmax = log.peekNext();
    const active_transactions = try log.getActiveTransactions(alloc);

    var xmin = xmax;
    for (active_transactions) |tid|
        xmin.v = @min(xmin.v, tid.v);

    return .{
        .log = log,
        .xmin = xmin,
        .xmax = xmax,
        .active_transactions = active_transactions,
        .my_tid = my_tid,
    };
}

/// Calculate the status of a specific transaction
fn transactionStatus(self: *const Snapshot, tid: ids.RealTransactionId) !transaction.Status {
    if (tid.v < self.xmin.v) {
        // The transaction is definitely already dead
        const status = try self.log.get(.{ .real = tid });
        std.debug.assert(status != .in_progress);
        return status;
    } else if (tid.v >= self.xmax.v) {
        // The transaction is in the future
        return .in_progress;
    } else {
        // Transaction might be active, try to find it in the snapshot
        const index = std.sort.binarySearch(
            ids.RealTransactionId,
            self.active_transactions,
            tid,
            struct {
                fn order(a: ids.RealTransactionId, b: ids.RealTransactionId) std.math.Order {
                    return std.math.order(a.v, b.v);
                }
            }.order,
        );
        if (index != null)
            // Transaction was active at the time of the snapshot
            return .in_progress
        else
            // Transaction was dead already
            return try self.log.get(.{ .real = tid });
    }
}

/// Are the changes made in the transaction visible for us?
pub fn changesVisible(self: *const Snapshot, tid: ids.RealTransactionId) !bool {
    if (tid.isInvalid()) {
        // Invalid transaction is always invisible
        return false;
    }

    if (tid.isFrozen()) {
        // Frozen transaction is always visible
        return true;
    }

    switch (self.my_tid) {
        .real => |r| if (tid == r) {
            // We are asking about the current transaction, of course it's visible
            return true;
        },
        .virtual => {},
    }

    return switch (try self.transactionStatus(tid)) {
        // Out of the normal transactions, only commited ones are visible.
        .in_progress => false,
        .committed => true,
        .aborted => false,
        .reserved => unreachable,
    };
}
