const std = @import("std");
const transaction = @import("transaction.zig");
const TransactionLog = @import("TransactionLog.zig");
const ids = @import("common").ids;

const Snapshot = @This();

log: *TransactionLog,
xmax: ids.RealTransactionId,
my_tid: transaction.Id,

pub fn create(log: *TransactionLog, my_tid: transaction.Id) Snapshot {
    return .{
        .log = log,
        .xmax = log.peekNext(),
        .my_tid = my_tid,
    };
}

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

pub fn changesVisible(self: *const Snapshot, tid: ids.RealTransactionId) !bool {
    if (tid == .invalid) {
        // Frozen transaction is always invisible
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
        .in_progress => false,
        .committed => true,
        .aborted => false,
        .reserved => unreachable,
    };
}
