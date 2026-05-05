//! This is an execution context, every node in the executor has access to this

const std = @import("std");

const catalog = @import("../catalog.zig");
const storage = @import("../storage.zig");
const common = @import("common");
const ids = common.ids;
const transaction = @import("../transaction.zig");
const Session = @import("../Session.zig");

alloc: std.mem.Allocator, // Allocator for tuples
s: *Session, // Common session data
snapshot: *const transaction.Snapshot,

sender: common.network.Message.Sender, // Message sender

pub const Error = error{
    MalformedData,
};
