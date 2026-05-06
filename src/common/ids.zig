//! Various numerical IDs used in the database.
//! All IDs are unsigned 32-bit integers.

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
};

pub const TLogFileId = u32;

pub const FullFileId = union(enum) {
    heap: FullTableId,
    tlog: TLogFileId,
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
};

pub const FullPageId = struct {
    file: FullFileId,
    page: PageId,
};

pub const RealTransactionId = enum(u32) {
    invalid = 0,
    frozen = 1,
    start = 32,
    _,

    pub fn next(self: RealTransactionId) RealTransactionId {
        return @enumFromInt(@intFromEnum(self) + 1);
    }
};
