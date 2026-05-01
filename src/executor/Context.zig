//! This is an execution context, every node in the executor has access to this

const std = @import("std");

const catalog = @import("../catalog.zig");
const storage = @import("../storage.zig");
const ids = @import("../ids.zig");
const data = @import("../data.zig");

alloc: std.mem.Allocator, // Allocator for tuples
catalog_cache: *catalog.Cache, // Catalog cache
storage_cache: *storage.Cache, // Storage cache
db_id: ids.DatabaseId, // Database id
output: *std.Io.Writer, // Text output for errors
data_output: std.ArrayList(data.MemTuple) = .empty, // Output for tuples

pub const Error = error{
    MalformedData,
};
