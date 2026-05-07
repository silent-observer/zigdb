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
const common = @import("common");
const ids = common.ids;
const oom = common.oom;

const Cache = @This();

/// Internal status of a page
const PageStatus = struct {
    dirty: bool = false,
    write_lock: std.Io.Mutex = .init,
    read_pins: std.atomic.Value(u8) = .init(0),
};

/// Page data after the pin is taken in the cache.
/// This has enough data to unlock the page afterwards.
pub const PinnedPage = struct {
    page: *RawDataFile.Page.Data,
    id: ids.FullPageId,
    writeable: bool,
};

// Mutex to ensure thread safety
mutex: std.Io.Mutex,
// Allocator used for all the page data
gpa: std.mem.Allocator,
// IO interface
io: std.Io,
// Path of the root of the database filesystem
base_path: []const u8,
// Hash map of currently open files
files: std.array_hash_map.Auto(ids.FullFileId, RawDataFile),
// Memory pool for pages (the actual cache data)
page_pool: std.heap.MemoryPool(RawDataFile.Page.Data),
// Hash map of pages
pages: std.array_hash_map.Auto(ids.FullPageId, *RawDataFile.Page.Data),
// Hash map of page statuses
page_status: std.array_hash_map.Auto(ids.FullPageId, PageStatus),

/// Initialize the page cache
pub fn init(gpa: std.mem.Allocator, io: std.Io, base_path: []const u8) Cache {
    return .{
        .mutex = .init,
        .gpa = gpa,
        .io = io,
        .base_path = base_path,
        .files = .empty,
        .page_pool = .empty,
        .pages = .empty,
        .page_status = .empty,
    };
}

/// Deinitialize all the page cache.
/// Note that data is *not* flushed, so changes might be lost.
pub fn deinit(self: *Cache) void {
    for (self.files.values()) |f| {
        f.close();
    }
    self.page_pool.deinit(self.gpa);
    self.files.deinit(self.gpa);
    self.pages.deinit(self.gpa);
    self.page_status.deinit(self.gpa);
}

/// Fetch a page (either read-only or read-write).
/// Also takes a pin for this page.
/// unpin must eventually be called on this page to avoid pin leaks.
fn fetch(
    self: *Cache,
    id: ids.FullPageId,
    writeable: bool,
) !PinnedPage {
    // All of this has to be mutexed since hash maps are not thread-safe
    try self.mutex.lock(self.io);
    defer self.mutex.unlock(self.io);

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

    if (writeable) {
        // Take the lock
        try status.value_ptr.write_lock.lock(self.io);
        // If we intend to write to the page, we will have to flush it later
        status.value_ptr.dirty = true;
    } else {
        // Take the pin
        const prev_pins =
            status.value_ptr.read_pins.fetchAdd(1, .acq_rel);
        std.debug.assert(prev_pins < 0xFF);
    } // Remove the pin if anything goes wrong
    errdefer if (writeable) {
        status.value_ptr.write_lock.unlock(self.io);
    } else {
        _ = status.value_ptr.read_pins.fetchSub(1, .acq_rel);
    };

    // Try to get the page status or create the entry if it isn't in the cache
    const page = self.pages.getOrPut(self.gpa, id) catch oom();
    // Remove the entry if anything goes wrong
    errdefer _ = self.pages.swapRemove(id);
    if (!page.found_existing) {
        page.value_ptr.* = self.page_pool.create(self.gpa) catch oom();
        // Read the page data if it wasn't in the cache
        try rdf.read(id.page, page.value_ptr.*);
    }

    // Form the PinnedPage to return
    return .{
        .page = page.value_ptr.*,
        .id = id,
        .writeable = writeable,
    };
}

/// Unpin the page.
pub fn unpin(
    self: *Cache,
    pinned_page: PinnedPage,
) void {
    // We assume you can't pin a page if it doesn't exist
    const status = self.page_status.getPtr(pinned_page.id).?;
    // Undo the pin
    if (pinned_page.writeable) {
        status.write_lock.unlock(self.io);
    } else {
        const prev_pins = status.read_pins.fetchSub(1, .acq_rel);
        std.debug.assert(prev_pins > 0);
    }
}

/// Upgrade the pin to writeable.
pub fn upgrade(
    self: *Cache,
    pinned_page: *PinnedPage,
) !void {
    if (pinned_page.writeable) return;
    // We assume you can't pin a page if it doesn't exist
    const status = self.page_status.getPtr(pinned_page.id).?;
    // Move the pin
    try status.write_lock.lock(self.io);

    const prev_read_pins = status.read_pins.fetchSub(1, .acq_rel);
    std.debug.assert(prev_read_pins < 0xFF);
}

/// Get a read-only page.
pub fn get(
    self: *Cache,
    id: ids.FullPageId,
) !PinnedPage {
    return try self.fetch(id, false);
}

/// Get a read-write page.
pub fn getWriteable(
    self: *Cache,
    id: ids.FullPageId,
) !PinnedPage {
    return try self.fetch(id, true);
}

/// Flush all dirty pages in the cache to disk.
pub fn flush(self: *Cache, force: bool) !void {
    // All of this has to be mutexed since hash maps are not thread-safe
    try self.mutex.lock(self.io);
    defer self.mutex.unlock(self.io);

    var iter = self.page_status.iterator();
    while (iter.next()) |e| {
        if (e.value_ptr.dirty) {
            if (!force and e.value_ptr.write_lock.state.load(.acquire) != .unlocked)
                continue;
            const file = self.files.get(e.key_ptr.file) orelse unreachable;
            const data = self.pages.get(e.key_ptr.*) orelse unreachable;
            try file.write(e.key_ptr.page, data);
            e.value_ptr.dirty = false;
        }
    }
}
