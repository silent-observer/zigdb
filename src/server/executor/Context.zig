//! This is an execution context, every node in the executor has access to this

const std = @import("std");

const catalog = @import("../catalog.zig");
const storage = @import("../storage.zig");
const common = @import("common");
const ids = common.ids;
const transaction = @import("../transaction.zig");

alloc: std.mem.Allocator, // Allocator for tuples
catalog_cache: *catalog.Cache, // Catalog cache
storage_cache: *storage.Cache, // Storage cache
transaction_log: *transaction.Log, // Transaction log

db_id: ids.DatabaseId, // Database id
tid: ids.TransactionId, // Current transaction id
snapshot: *const transaction.Snapshot,

output: *std.Io.Writer, // Text output for errors
data_output: std.ArrayList(common.MemTuple) = .empty, // Output for tuples

pub const Error = error{
    MalformedData,
};
