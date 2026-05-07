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
    vars: void,
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
