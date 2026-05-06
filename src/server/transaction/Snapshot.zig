//! This represents a snapshot of a state of a database at some point in time.
//! Currently concurrent transactions are not supported, so it's enough to remember
//! which transaction was the last one that has completed.

const std = @import("std");
const transaction = @import("transaction.zig");
const TransactionLog = @import("TransactionLog.zig");
const ids = @import("common").ids;

const Snapshot = @This();

/// Transaction log for looking up transactions.
log: *TransactionLog,
/// The earliest transaction that hasn't yet started.
/// Everything starting from this is surely not visible yet.
xmax: ids.RealTransactionId,
/// ID of the current transaction. Our own actions are always visible.
my_tid: transaction.Id,

/// Create a new snapshot
pub fn create(log: *TransactionLog, my_tid: transaction.Id) Snapshot {
    return .{
        .log = log,
        .xmax = log.peekNext(),
        .my_tid = my_tid,
    };
}

/// Calculate the status of a specific transaction
pub fn transactionStatus(self: *const Snapshot, tid: ids.RealTransactionId) !transaction.Status {
    if (@intFromEnum(tid) >= @intFromEnum(self.xmax)) {
        // The transaction is in the future
        return .in_progress;
    } else {
        // Transaction might be active
        // TODO: Concurrent transactions
        return try self.log.get(.{ .real = tid });
    }
}

/// Are the changes made in the transaction visible for us?
pub fn changesVisible(self: *const Snapshot, tid: ids.RealTransactionId) !bool {
    if (tid == .invalid) {
        // Invalid transaction is always invisible
        return false;
    }

    if (tid == .frozen) {
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
