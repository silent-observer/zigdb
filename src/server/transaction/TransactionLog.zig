const std = @import("std");
const common = @import("common");
const storage = @import("../storage.zig");
const transaction = @import("transaction.zig");
const ids = common.ids;
const oom = common.oom;

const TransactionLog = @This();

next_tid: ids.TransactionId = .start,
storage_cache: *storage.Cache,

const status_count_per_byte = 4;
const status_count_per_page = storage.Page.Size * status_count_per_byte;
const max_pages_per_file = 1024;

const Address = struct {
    page_id: ids.FullPageId,
    byte_index: u16,
    bit_shift: u3,
};

pub fn init(storage_cache: *storage.Cache) TransactionLog {
    return .{ .storage_cache = storage_cache };
}

fn split(tid: ids.TransactionId) Address {
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

pub fn get(self: *TransactionLog, tid: ids.TransactionId) !transaction.Status {
    const addr = split(tid);
    const page = try self.storage_cache.get(addr.page_id);
    defer self.storage_cache.unpin(page);

    const byte = page.page.d[addr.byte_index];
    return @enumFromInt((byte >> addr.bit_shift) & 0x3);
}

pub fn set(self: *TransactionLog, tid: ids.TransactionId, status: transaction.Status) !void {
    const addr = split(tid);
    const page = try self.storage_cache.getWriteable(addr.page_id);
    defer self.storage_cache.unpin(page);

    const byte = &page.page.d[addr.byte_index];
    const mask: u8 = @as(u8, 0x3) << addr.bit_shift;
    byte.* = (byte.* & ~mask) | (@as(u8, @intFromEnum(status)) << addr.bit_shift);
}

pub fn next(self: *TransactionLog) ids.TransactionId {
    defer self.next_tid = self.next_tid.next();
    return self.next_tid;
}
