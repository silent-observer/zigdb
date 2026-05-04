const std = @import("std");
const transaction = @import("transaction.zig");
const TransactionLog = @import("TransactionLog.zig");
const ids = @import("common").ids;

const Snapshot = @This();

log: *TransactionLog,
xmin: ids.TransactionId,
xmax: ids.TransactionId,
my_tid: ids.TransactionId,

pub fn create(log: *TransactionLog, my_tid: ids.TransactionId) Snapshot {
    return .{
        .log = log,
        .xmin = my_tid,
        .xmax = my_tid.next(),
        .my_tid = my_tid,
    };
}

pub fn transactionStatus(self: *const Snapshot, tid: ids.TransactionId) !transaction.Status {
    if (@intFromEnum(tid) < @intFromEnum(self.xmin)) {
        // The transaction is already dead
        return try self.log.get(tid);
    } else if (@intFromEnum(tid) >= @intFromEnum(self.xmax)) {
        // The transaction is in the future
        return .in_progress;
    } else {
        // Transaction might be active
        // TODO: Concurrent transactions
        return try self.log.get(tid);
    }
}

pub fn changesVisible(self: *const Snapshot, tid: ids.TransactionId) !bool {
    if (tid == .invalid) {
        // Frozen transaction is always invisible
        return false;
    }

    if (tid == .frozen) {
        // Frozen transaction is always visible
        return true;
    }

    if (tid == self.my_tid) {
        // We are asking about the current transaction, of course it's visible
        return true;
    }

    return switch (try self.transactionStatus(tid)) {
        .in_progress => false,
        .committed => true,
        .aborted => false,
        .reserved => unreachable,
    };
}
