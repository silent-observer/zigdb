//! Representation of a data file.
//!
//! The file is split into fixed-size pages (8 KB each).
//! The only way to access the file is to read/write whole pages.

const std = @import("std");
const Io = std.Io;
const ids = @import("../ids.zig");

pub const Page = struct {
    /// Each page is 8 KB
    pub const Size = 8 * 1024;
    /// Page data must be aligned to 16 bytes in memory.
    pub const Data = extern struct { d: [Size]u8 align(16) };
    /// Sequential index of a page in the file, starting from 0.
    pub const Id = ids.PageId;
};

const RawDataFile = @This();

io: Io,
file: Io.File,

/// Full Id, necessary to identify a specific file.
pub const Id = ids.FullFileId;
/// Maximum allowed length of a file path.
pub const PathMaxLen = 1024;

/// Open a data file, create it if it doesn't exist.
/// base_path is the root of the database filesystem.
pub fn open(io: Io, base_path: []const u8, id: Id) !RawDataFile {
    var buf: [PathMaxLen]u8 = undefined;
    var alloc = std.heap.FixedBufferAllocator.init(&buf);

    const base_dir = try Io.Dir.openDirAbsolute(io, base_path, .{});
    const db_dir_path = std.fmt.allocPrint(alloc.allocator(), "db{}", .{id.db}) catch unreachable;
    const db_dir = try base_dir.createDirPathOpen(io, db_dir_path, .{});

    const filename = std.fmt.allocPrint(alloc.allocator(), "{}.data", .{id.table}) catch unreachable;
    const f = try db_dir.createFile(
        io,
        filename,
        .{ .truncate = false, .read = true },
    );
    return .{
        .io = io,
        .file = f,
    };
}

/// Close the data file.
pub fn close(self: *const RawDataFile) void {
    self.file.close(self.io);
}

/// Read a whole page with a given id into the `out` pointer.
/// If the page doesn't exist in the file, it is assumed to be filled with zeros.
pub fn read(self: *const RawDataFile, id: Page.Id, out: *Page.Data) !void {
    const offset = @as(u64, @intCast(id)) * Page.Size;
    const r = try self.file.readPositionalAll(self.io, &out.d, offset);
    if (r == 0) {
        @memset(&out.d, 0);
    } else std.debug.assert(r == Page.Size);
}

/// Write a whole page with a given id.
pub fn write(self: *const RawDataFile, id: Page.Id, data: *const Page.Data) !void {
    const offset = @as(u64, @intCast(id)) * Page.Size;
    try self.file.writePositionalAll(self.io, &data.d, offset);
}
