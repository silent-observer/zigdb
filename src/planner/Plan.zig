//! Representation of various parts of a plan

const std = @import("std");

const data = @import("../data.zig");
const ids = @import("../ids.zig");
const ast = @import("../sql/ast.zig");

/// This is a column index inside a given tuple descriptor.
pub const ColumnId = u16;

/// Plan for a statement. The root of any plan.
pub const Statement = union(enum) {
    select: Select,
    insert: Insert,
    delete: Delete,
    create_table: CreateTable,
    drop_table: DropTable,
    truncate: Truncate,

    pub const Select = struct {
        /// Source of the data
        root: *DataNode,
    };

    pub const Insert = struct {
        /// Table to insert rows into
        table: ids.TableId,
        /// Source of the data
        root: *DataNode,
    };

    pub const Delete = struct {
        /// Table to delete rows from
        table: ids.TableId,
        /// Source of the data
        root: *DataNode,
    };

    pub const CreateTable = struct {
        /// Name of the table to create
        name: []const u8,
        /// Descriptor for the new table
        descr: *const data.TupleDescriptor,
    };

    pub const DropTable = struct {
        /// Id of the table to be dropped
        table: ids.TableId,
    };

    pub const Truncate = struct {
        /// Id of the table to be truncated
        table: ids.TableId,
    };
};

/// A node that can return a stream of rows.
/// They usually form the bulk of the plan.
pub const DataNode = struct {
    action: Action, // Type of the data node
    descr: *const data.TupleDescriptor, // Descriptor for rows it returns
    state: ?*anyopaque = null, // Internal state of the node

    pub const Action = union(enum) {
        full_scan: FullScan,
        values: Values,
        project: Project,
        filter: Filter,

        /// Performs a full scan of some table
        pub const FullScan = struct {
            /// Table to scan
            table: ids.TableId,
        };

        /// Returns rows defined in the query itself
        pub const Values = struct {
            /// Rows to return
            data: std.ArrayList(data.MemTuple),
        };

        /// Projects input data by executing scalar expressions on it.
        pub const Project = struct {
            /// Input data source
            input: *DataNode,
            /// Expressions to execute and return
            exprs: std.ArrayList(ScalarNode),
        };

        /// Filters input data, only leaving rows that fit the condition.
        pub const Filter = struct {
            /// Input data source
            input: *DataNode,
            /// Condition to check
            condition: *ScalarNode,
        };
    };

    /// Format the DataNode as JSON (skipping private `state` field)
    pub fn jsonStringify(self: *const DataNode, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("action");
        try jws.write(self.action);
        try jws.objectField("descr");
        try jws.write(self.descr);
        try jws.endObject();
    }
};

/// A node that can return a scalar value.
/// Must be executed in the context of some tuple.
pub const ScalarNode = struct {
    dbtype: data.DBType, // Type of value it returns
    action: Action, // Type of node

    pub const Action = union(enum) {
        column: ColumnId, // Value from a column
        value: data.Value, // Constant value
        unary: Unary, // Unary operation
        binary: Binary, // Binary operation
    };

    pub const Unary = struct {
        op: Op,
        child: *ScalarNode,

        pub const Op = ast.Expression.Unary.Op;
    };

    pub const Binary = struct {
        op: Op,
        left: *ScalarNode,
        right: *ScalarNode,

        pub const Op = ast.Expression.Binary.Op;
    };
};
