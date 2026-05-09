//! Various numerical IDs used in the database.
//! All IDs are unsigned 32-bit integers.

const std = @import("std");

/// Id of the database
pub const DatabaseId = u32;
/// Id of any database object
pub const ObjectId = u32;
/// Id of a table inside a database
pub const TableId = ObjectId;
/// Full Id sufficient to identify a specific table
pub const FullTableId = extern struct {
    db: DatabaseId,
    table: TableId,

    pub fn fullFileId(self: FullTableId) FullFileId {
        return .{ .heap = self };
    }

    /// Format the FullTableId as {db}/{table}
    pub fn format(
        self: FullTableId,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("{}/{}", .{ self.db, self.table });
    }
};

pub const TLogFileId = u32;

pub const FullFileId = union(enum) {
    heap: FullTableId,
    tlog: TLogFileId,
    vars: void,

    /// Format the FullFileId
    pub fn format(
        self: FullFileId,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .heap => |h| try writer.print("heap/{f}", .{h}),
            .tlog => |tlog| try writer.print("tlog/{}", .{tlog}),
            .vars => try writer.print("vars", .{}),
        }
    }
};

/// Id of page inside a data file
pub const PageId = u32;
/// Full Id sufficient to identify a specific page
pub const FullHeapPageId = extern struct {
    table: FullTableId,
    page: PageId,

    pub fn fullPageId(self: FullHeapPageId) FullPageId {
        return .{
            .file = .{ .heap = self.file },
            .page = self.page,
        };
    }

    /// Format the FullHeapPageId as {db}/{table}@{page}
    pub fn format(
        self: FullHeapPageId,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("{f}@{}", .{ self.table, self.page });
    }
};

pub const FullPageId = struct {
    file: FullFileId,
    page: PageId,

    /// Format the FullPageId as {db}/{table}@{page}
    pub fn format(
        self: FullPageId,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("{f}@{}", .{ self.file, self.page });
    }
};

pub const RealTransactionId = packed struct(u32) {
    v: u32,

    pub const invalid: RealTransactionId = .{ .v = 0 };
    pub const frozen: RealTransactionId = .{ .v = 1 };
    pub const start: RealTransactionId = .{ .v = 32 };

    pub fn next(self: RealTransactionId) RealTransactionId {
        return .{ .v = self.v + 1 };
    }

    pub fn isInvalid(self: RealTransactionId) bool {
        return self.v == invalid.v;
    }
    pub fn isFrozen(self: RealTransactionId) bool {
        return self.v == frozen.v;
    }
};
