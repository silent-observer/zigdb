//! This is a log of transaction statuses.
//! It allows you to check the status of any past transaction.
//! Note that no special caching is used, we rely on regular storage cache for this.

const std = @import("std");
const common = @import("common");
const storage = @import("../storage.zig");
const transaction = @import("transaction.zig");
const ids = common.ids;
const oom = common.oom;

const TransactionLog = @This();

/// The id of the next transaction
next_tid: std.atomic.Value(u32),
storage_cache: *storage.Cache,

/// Each transaction status is 2 bits, so we can fit 4 of them in one byte.
const status_count_per_byte = 4;
/// We can fit a lot more in a whole page.
const status_count_per_page = storage.Page.Size * status_count_per_byte;
/// We split the log into small-ish files to allow eventual cleanup of outdated files.
const max_pages_per_file = 1024;

/// A full "address" of a transaction in the log
const Address = struct {
    page_id: ids.FullPageId, // Id of a file and page in it
    byte_index: u16, // Index of a byte on the page
    bit_shift: u3, // Index of a bit in the byte (can only be 0, 2, 4 or 6)
};

/// Initialize the transaction log
pub fn init(storage_cache: *storage.Cache) TransactionLog {
    return .{
        .next_tid = .init(@intFromEnum(ids.RealTransactionId.start)),
        .storage_cache = storage_cache,
    };
}

/// Calculate the address from transaction ID.
fn split(tid: ids.RealTransactionId) Address {
    const file_id = @intFromEnum(tid) / (max_pages_per_file * status_count_per_page);
    const page_id = (@intFromEnum(tid) / status_count_per_page) % max_pages_per_file;
    const index = @intFromEnum(tid) % status_count_per_page;
    const byte_index = index / status_count_per_byte;
    const bit_shift = (index % status_count_per_byte) * 2;
    return .{
        .page_id = .{
            .file = .{ .tlog = file_id },
            .page = page_id,
        },
        .byte_index = @intCast(byte_index),
        .bit_shift = @intCast(bit_shift),
    };
}

/// Read the status of some specific transaction from the log.
pub fn get(self: *TransactionLog, tid: transaction.Id) !transaction.Status {
    switch (tid) {
        .virtual => return .in_progress, // Virtual transactions are always in progress
        .real => |rtid| {
            const addr = split(rtid);
            const page = try self.storage_cache.get(addr.page_id);
            defer self.storage_cache.unpin(page);

            const byte = page.page.d[addr.byte_index];
            return @enumFromInt((byte >> addr.bit_shift) & 0x3);
        },
    }
}

/// Write the status of some specific transaction into the log.
pub fn set(self: *TransactionLog, tid: transaction.Id, status: transaction.Status) !void {
    switch (tid) {
        .virtual => {}, // Nothing to do for a virtual transaction
        .real => |rtid| {
            const addr = split(rtid);
            const page = try self.storage_cache.getWriteable(addr.page_id);
            defer self.storage_cache.unpin(page);

            const byte = &page.page.d[addr.byte_index];
            const mask: u8 = @as(u8, 0x3) << addr.bit_shift;
            byte.* = (byte.* & ~mask) | (@as(u8, @intFromEnum(status)) << addr.bit_shift);
        },
    }
}

/// What the id ID for the next transaction is going to be?
pub fn peekNext(self: *TransactionLog) ids.RealTransactionId {
    return @enumFromInt(self.next_tid.load(.acquire));
}

/// Generate a new ID for a transaction.
pub fn next(self: *TransactionLog) ids.RealTransactionId {
    return @enumFromInt(self.next_tid.fetchAdd(1, .acq_rel));
}

/// Get a real transaction isntead of a virtual one, if we didn't have one already.
pub fn startRealTransaction(self: *TransactionLog, out: *transaction.Id) void {
    switch (out.*) {
        .real => {},
        .virtual => out.* = .{ .real = self.next() },
    }
}
