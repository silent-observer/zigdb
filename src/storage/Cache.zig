//! This is an in-memory page cache.
//! All file operations must go through this cache instead of operating
//! on the RawDataFiles directly.
//!
//! Both reading and writing pages requires you to take a lock to avoid
//! accidental concurrent reads. (Note that concurrency is not implmented yet).
//!
//! When you read from the cache, if the page is not yet present in the cache
//! it is fetched from disk.
//! When you write to the cache, nothing is written on disk, only the memory
//! in the cache is modified. Data on disk is only modified when the cache
//! is flushed.

const std = @import("std");

const RawDataFile = @import("RawDataFile.zig");
const ids = @import("../ids.zig");
const oom = @import("../utils.zig").oom;

const Cache = @This();

/// Internal status of a page
const PageStatus = struct {
    dirty: bool = false,
    lock: std.Io.RwLock = std.Io.RwLock.init,
};

/// Page data after the lock is taken in the cache.
/// This has enough data to unlock the page afterwards.
pub const LockedPage = struct {
    page: *RawDataFile.Page.Data,
    id: ids.FullPageId,
    writeable: bool,
};

// Allocator used for all the page data
gpa: std.mem.Allocator,
// IO interface
io: std.Io,
// Path of the root of the database filesystem
base_path: []const u8,
// Hash map of currently open files
files: std.array_hash_map.Auto(ids.FullFileId, RawDataFile),
// Hash map of pages (the actual cache data)
pages: std.array_hash_map.Auto(ids.FullPageId, RawDataFile.Page.Data),
// Hash map of page statuses
page_status: std.array_hash_map.Auto(ids.FullPageId, PageStatus),

/// Initialize the page cache
pub fn init(gpa: std.mem.Allocator, io: std.Io, base_path: []const u8) Cache {
    return .{
        .gpa = gpa,
        .io = io,
        .base_path = base_path,
        .files = std.array_hash_map.Auto(ids.FullFileId, RawDataFile).init(gpa, &.{}, &.{}) catch oom(),
        .pages = std.array_hash_map.Auto(ids.FullPageId, RawDataFile.Page.Data).init(gpa, &.{}, &.{}) catch oom(),
        .page_status = std.array_hash_map.Auto(ids.FullPageId, PageStatus).init(gpa, &.{}, &.{}) catch oom(),
    };
}

/// Deinitialize all the page cache.
/// Note that data is *not* flushed, so changes might be lost.
pub fn deinit(self: *Cache) void {
    for (self.files.values()) |f| {
        f.close();
    }
    self.files.deinit(self.gpa);
    self.pages.deinit(self.gpa);
    self.page_status.deinit(self.gpa);
}

/// Fetch a page (either read-only or read-write).
/// Also takes a lock for this page.
/// unlock must eventually be called on this page to avoid lock leaks.
fn fetch(
    self: *Cache,
    id: ids.FullPageId,
    writeable: bool,
) !LockedPage {
    // Try to get the file or create the entry for it if it isn't opened
    const file = self.files.getOrPut(self.gpa, id.file) catch oom();
    // Remove the entry if anything goes wrong
    errdefer _ = self.files.swapRemove(id.file);
    if (!file.found_existing) {
        // Open the file if it isn't open already
        file.value_ptr.* = try RawDataFile.open(self.io, self.base_path, id.file);
    }
    // This is the file in question
    const rdf = file.value_ptr.*;

    // Try to get the page status or create the entry if it doesn't exist yet
    const status = self.page_status.getOrPut(self.gpa, id) catch oom();
    // Remove the entry if anything goes wrong
    errdefer _ = self.page_status.swapRemove(id);
    if (!status.found_existing) {
        // Initialize the status if it wasn't in the cache before
        status.value_ptr.* = .{};
    }

    // Take the read-write or read-only lock
    if (writeable) {
        try status.value_ptr.lock.lock(self.io);
        // If we intend to write to the page, we will have to flush it later
        status.value_ptr.dirty = true;
    } else {
        try status.value_ptr.lock.lockShared(self.io);
    }

    // Try to get the page status or create the entry if it isn't in the cache
    const page = self.pages.getOrPut(self.gpa, id) catch oom();
    // Remove the entry if anything goes wrong
    errdefer _ = self.pages.swapRemove(id);
    if (!page.found_existing) {
        // Read the page data if it wasn't in the cache
        try rdf.read(id.page, page.value_ptr);
    }

    // Form the LockedPage to return
    return .{
        .page = page.value_ptr,
        .id = id,
        .writeable = writeable,
    };
}

/// Unlock the page.
pub fn unlock(
    self: *Cache,
    locked_page: LockedPage,
) void {
    // We assume you can't lock a page if it doesn't exist.
    const status = self.page_status.getPtr(locked_page.id).?;
    // Undo the read-write or read-only lock.
    if (locked_page.writeable) {
        status.lock.unlock(self.io);
    } else {
        status.lock.unlockShared(self.io);
    }
}

/// Get a read-only page.
pub fn get(
    self: *Cache,
    id: ids.FullPageId,
) !LockedPage {
    return try self.fetch(id, false);
}

/// Get a read-write page.
pub fn getWriteable(
    self: *Cache,
    id: ids.FullPageId,
) !LockedPage {
    return try self.fetch(id, true);
}

/// Flush all dirty pages in the cache to disk.
pub fn flush(self: *Cache) !void {
    var iter = self.page_status.iterator();
    while (iter.next()) |e| {
        if (e.value_ptr.dirty) {
            const file = self.files.get(e.key_ptr.file) orelse unreachable;
            const data = self.pages.getPtr(e.key_ptr.*) orelse unreachable;
            try file.write(e.key_ptr.page, data);
            e.value_ptr.dirty = false;
        }
    }
}
