//! This is an execution context, every node in the executor has access to this

const std = @import("std");

const catalog = @import("../catalog.zig");
const storage = @import("../storage.zig");
const common = @import("common");
const ids = common.ids;
const transaction = @import("../transaction.zig");
const Session = @import("../Session.zig");

alloc: std.mem.Allocator, // Allocator for tuples
snapshot: *const transaction.Snapshot, // Current snapshot

pub const Error = error{
    MalformedData,
};
