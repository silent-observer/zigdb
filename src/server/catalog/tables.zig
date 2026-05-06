//! Information about all catalog tables.
//!
//! The catalog tables are the system tables containing the metadata
//! about the database.
//!
//! Each catalog table is simply a normal heap table, however they have
//! fixed table ids, so they can be accessed by the database code. Each
//! database has its own copy of a catalog.
//!
//! Below is the current catalog schema:
//!
//! ```sql
//! -- Tables
//! CREATE TABLE zdb_rels (
//!     rel_id      UINT4 PRIMARY KEY,  -- table id
//!     rel_name    TEXT                -- table name
//! );
//! -- Attributes of tables
//! CREATE TABLE zdb_attrs (
//!     attr_rel_id UINT4,  -- table id
//!     attr_id     UINT4,  -- attribute id inside the table
//!     attr_type   UINT4,  -- type if of the attribute
//!     attr_name   TEXT,   -- attribute name
//!     PRIMARY KEY (attr_rel_id, attr_id)
//! );
//! -- Sequences
//! CREATE TABLE zdb_rels (
//!     seq_id      UINT4 PRIMARY KEY,  -- sequence id
//!     seq_name    TEXT,               -- sequence name
//!     seq_val     UINT4               -- current value of the sequence
//! );
//! ```
//!
//! All the catalog tables are self-described in zdb_rels and zdb_attrs tables.
//! There are also default sequences named seq_table_id and seq_seq_id, used for
//! choosing ids for user-created tables and sequences.
//! All user ids start at 1000.

const std = @import("std");

const HeapTable = @import("../heap/HeapTable.zig");
const common = @import("common");
const oom = common.oom;

/// Fixed table ids of catalog tables.
pub const TableId = enum(common.ids.TableId) {
    zdb_rels = 1,
    zdb_attrs = 2,
    zdb_seqs = 3,
};

/// Enum used to refer to specific system attributes.
/// Does not correspond to real attribute ids.
pub const SystemAttribute = enum {
    // zdb_rels
    rel_id,
    rel_name,
    // zdb_attrs
    attr_rel_id,
    attr_id,
    attr_type,
    attr_name,
    // zdb_seq
    seq_id,
    seq_name,
    seq_val,
};

/// Fixed sequence ids of catalog sequences.
pub const SequenceId = enum(common.ids.TableId) {
    zdb_seq_table_id = 0,
    zdb_seq_seq_id = 1,
};

/// Internal entry for each catalog attribute.
/// Used for comptime code generation.
const AttributeEntry = struct {
    id: SystemAttribute,
    db_type: common.DBType,
    t: type,
};

/// Internal entry for each catalog table.
/// Used for comptime code generation.
const TableEntry = struct {
    id: TableId,
    attrs: []const AttributeEntry,
};

/// Descriptions of all catalog tables.
const Tables: []const TableEntry = &.{
    TableEntry{
        .id = .zdb_rels,
        .attrs = &.{
            AttributeEntry{
                .id = .rel_id,
                .db_type = .oid,
                .t = u32,
            },
            AttributeEntry{
                .id = .rel_name,
                .db_type = .text,
                .t = []const u8,
            },
        },
    },
    TableEntry{
        .id = .zdb_attrs,
        .attrs = &.{
            AttributeEntry{
                .id = .attr_rel_id,
                .db_type = .oid,
                .t = u32,
            },
            AttributeEntry{
                .id = .attr_id,
                .db_type = .uint1,
                .t = u8,
            },
            AttributeEntry{
                .id = .attr_type,
                .db_type = .uint4,
                .t = u32,
            },
            AttributeEntry{
                .id = .attr_name,
                .db_type = .text,
                .t = []const u8,
            },
        },
    },
    TableEntry{
        .id = .zdb_seqs,
        .attrs = &.{
            AttributeEntry{
                .id = .seq_id,
                .db_type = .oid,
                .t = u32,
            },
            AttributeEntry{
                .id = .seq_name,
                .db_type = .text,
                .t = []const u8,
            },
            AttributeEntry{
                .id = .seq_val,
                .db_type = .uint4,
                .t = u32,
            },
        },
    },
};

/// Internal data for each system attribute.
const AttributeData = struct {
    rel: TableId,
    index: u8,
    t: type,
};

/// Comptime-generated array of all system attributes.
const AttributeDataArr = fillAttrData();

/// Comptime function to fill all the system attribute metadata.
fn fillAttrData() std.EnumArray(SystemAttribute, AttributeData) {
    // Initialize the array
    var result: std.EnumArray(SystemAttribute, AttributeData) = .initUndefined();
    // Go through all the system tables
    inline for (Tables) |r| {
        // Go through all the attributes
        inline for (r.attrs, 0..) |a, i| {
            // Fill in the data corresponding to SystemAttribute
            result.set(a.id, AttributeData{
                .rel = r.id,
                .index = i,
                .t = a.t,
            });
        }
    }
    return result;
}

/// Function to fill all the TupleDescriptors of system tables.
/// Can only be called at runtime because TupleDescriptor requires allocation.
fn fillDescriptors(gpa: std.mem.Allocator) std.EnumArray(TableId, common.TupleDescriptor) {
    var result = std.EnumArray(TableId, common.TupleDescriptor).initUndefined();
    inline for (Tables) |r| {
        var descr = common.TupleDescriptor.emptyExtended;
        descr.attrs.ensureUnusedCapacity(gpa, r.attrs.len) catch oom();
        inline for (r.attrs) |a| {
            descr.attrs.appendAssumeCapacity(.{
                .name = @tagName(a.id),
                .t = a.db_type,
            });
        }
        result.set(r.id, descr);
    }
    return result;
}

/// Array of all tuple descriptors of system tables.
/// It's the same for every database, so it's okay to have in a global variable.
var descriptors =
    std.EnumArray(TableId, common.TupleDescriptor).initUndefined();

/// Initialize the descriptor array.
/// Must be done once at the start of the process.
/// The Allocator can be one that survives for the entire lifetime of the process.
pub fn init(gpa: std.mem.Allocator) void {
    descriptors = fillDescriptors(gpa);
}

/// Get attribute index corresponding to a SystemAttribute.
pub fn index(comptime id: SystemAttribute) u8 {
    return AttributeDataArr.get(id).index;
}

/// Get which table SystemAttribute belongs to.
pub fn table(comptime id: SystemAttribute) TableId {
    return AttributeDataArr.get(id).rel;
}

/// The type of a given SystemAttribute.
pub fn Attr(comptime id: SystemAttribute) type {
    return AttributeDataArr.get(id).t;
}

/// Get the TupleDescriptor of the system table.
pub fn descriptor(id: TableId) *const common.TupleDescriptor {
    return descriptors.getPtr(id);
}

/// Generated type corresponding to a row of a system table.
/// This type is constructed at comptime from the description of the system table.
pub fn Entry(comptime id: TableId) type {
    // Description of the system table
    const r = Tables[@intFromEnum(id) - 1];
    // Arrays describing fields of the generated type
    var field_names: [r.attrs.len][]const u8 = undefined;
    var field_types: [r.attrs.len]type = undefined;
    var field_attrs: [r.attrs.len]std.builtin.Type.StructField.Attributes = undefined;
    // Go through all attributes and fill the field metadata
    for (r.attrs, 0..) |a, i| {
        field_names[i] = @tagName(a.id);
        field_types[i] = a.t;
        field_attrs[i] = .{};
    }
    // Construct the final type
    return @Struct(
        .auto,
        null,
        &field_names,
        &field_types,
        &field_attrs,
    );
}
