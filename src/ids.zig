//! Various numerical IDs used in the database.
//! All IDs are unsigned 32-bit integers.

/// Id of the database
pub const DatabaseId = u32;
/// Id of a table inside a database
pub const TableId = u32;
/// Full Id sufficient to identify a specific table
pub const FullTableId = extern struct {
    db: DatabaseId,
    table: TableId,
};
/// Files correspond 1-to-1 to tables.
pub const FullFileId = FullTableId;

/// Id of page inside a data file
pub const PageId = u32;
/// Full Id sufficient to identify a specific page
pub const FullPageId = extern struct {
    file: FullFileId,
    page: PageId,
};
