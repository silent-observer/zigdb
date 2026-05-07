//! Cache for various system variables.
//! Currently used to store global ObjectId and TransactionId counters.
//! This is actually stored on-disk in a single-page "vars" file.

const std = @import("std");
const common = @import("common");
const storage = @import("storage.zig");
const ids = common.ids;

const VariablesCache = @This();

storage_cache: *storage.Cache,
vars: Variables,

/// The contents of the "vars" file.
const Variables = extern struct {
    /// Magic value for variables file
    magic_value: [8]u8 = Magic,
    /// Transaction ID counter
    tid_counter: std.atomic.Value(u32) = .init(ids.RealTransactionId.start.v),
    /// Object ID counter
    oid_counter: std.atomic.Value(ids.ObjectId) = .init(1000),

    const Magic: [8]u8 = .{ 'Z', 'D', 'B', '_', 'V', 'A', 'R', 'S' };

    /// Obtain a header from raw page (and check the magic number)
    pub fn fromPage(page: *storage.Page.Data) ?*Variables {
        const h: *Variables = @ptrCast(page);
        if (std.meta.eql(h.magic_value, Magic))
            return h
        else
            return null;
    }

    /// Write the header page
    pub fn writePage(h: *const Variables, page: *storage.Page.Data) void {
        @memset(&page.d, 0);
        const dest: *Variables = @ptrCast(&page.d);
        dest.* = h.*;
    }
};

/// Initialize the cache and the "vars" file.
pub fn init(storage_cache: *storage.Cache) !VariablesCache {
    const page = try storage_cache.get(.{
        .file = .vars,
        .page = 0,
    });
    defer storage_cache.unpin(page);

    const vars = if (Variables.fromPage(page.page)) |vars|
        vars.* // Read the current data if "vars" file exists
    else
        Variables{}; // Initialize it if it doesn't yet
    const cache = VariablesCache{
        .storage_cache = storage_cache,
        .vars = vars,
    };
    try cache.updateVariablesOnDisk();
    return cache;
}

/// Write the updated variable state to "vars" file.
fn updateVariablesOnDisk(self: *const VariablesCache) !void {
    const page = try self.storage_cache.getWriteable(.{
        .file = .vars,
        .page = 0,
    });
    defer self.storage_cache.unpin(page);

    self.vars.writePage(page.page);
}

/// Get the Id of the next transaction (without allocating it)
pub fn peekTransactionId(self: *VariablesCache) ids.RealTransactionId {
    return .{ .v = self.vars.tid_counter.load(.acquire) };
}

/// Generate the Id of the next transaction and take it for ourselves,
/// incrementing the counter.
pub fn nextTransactionId(self: *VariablesCache) !ids.RealTransactionId {
    const id = self.vars.tid_counter.fetchAdd(1, .acq_rel);
    try self.updateVariablesOnDisk();
    return .{ .v = id };
}

/// Generate the next ObjectId
pub fn nextObjectId(self: *VariablesCache) !ids.ObjectId {
    const id = self.vars.oid_counter.fetchAdd(1, .acq_rel);
    try self.updateVariablesOnDisk();
    return id;
}
