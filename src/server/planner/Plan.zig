//! Representation of various parts of a plan

const std = @import("std");

const common = @import("common");
const ids = common.ids;
const ast = @import("../sql/ast.zig");

/// This is a column index inside a given tuple descriptor.
pub const ColumnId = u16;

/// Plan for a statement. The root of any plan.
pub const Statement = union(enum) {
    select: Select,
    insert: Insert,
    delete: Delete,
    update: Update,
    create_table: CreateTable,
    drop_table: DropTable,
    truncate: Truncate,
    begin: void,
    commit: void,
    rollback: void,

    pub const Select = struct {
        /// Source of the data
        root: *DataNode,
    };

    pub const Insert = struct {
        /// Table to insert rows into
        table: ids.TableId,
        /// Optional toast table
        toast_table: ?ids.TableId,
        /// Source of the data
        root: *DataNode,
    };

    pub const Delete = struct {
        /// Table to delete rows from
        table: ids.TableId,
        /// Source of the data
        root: *DataNode,
    };

    pub const Update = struct {
        /// Table to update rows in
        table: ids.TableId,
        /// Optional toast table
        toast_table: ?ids.TableId,
        /// Source of the data
        root: *DataNode,
        /// Columns that need updating
        cols: []ColumnId,
        /// Expressions for columns
        vals: []ScalarNode,
    };

    pub const CreateTable = struct {
        /// Name of the table to create
        name: []const u8,
        /// Descriptor for the new table
        descr: *const common.TupleDescriptor,
    };

    pub const DropTable = struct {
        /// Id of the table to be dropped
        table: ids.TableId,
        /// Optional toast table
        toast_table: ?ids.TableId,
    };

    pub const Truncate = struct {
        /// Id of the table to be truncated
        table: ids.TableId,
        /// Optional toast table
        toast_table: ?ids.TableId,
    };
};

/// A node that can return a stream of rows.
/// They usually form the bulk of the plan.
pub const DataNode = struct {
    action: Action, // Type of the data node
    descr: *const common.TupleDescriptor, // Descriptor for rows it returns
    state: ?*anyopaque = null, // Internal state of the node

    pub const Action = union(enum) {
        full_scan: FullScan,
        values: Values,
        project: Project,
        filter: Filter,
        nested_loop: NestedLoop,
        union_all: UnionAll,

        /// Performs a full scan of some table
        pub const FullScan = struct {
            /// Table to scan
            table: ids.TableId,
        };

        /// Returns rows defined in the query itself
        pub const Values = struct {
            /// Rows to return
            data: []common.MemTuple,
        };

        /// Projects input data by executing scalar expressions on it.
        pub const Project = struct {
            /// Input data source
            input: *DataNode,
            /// Expressions to execute and return
            exprs: []ScalarNode,
            /// Special operation to perform
            op: Op,

            pub const Op = enum {
                evaluate, // Evaluate all the expressions
                copy, // Simply copy the input tuple
                // All the missing attributes are assumed to be at the start of the tuple,
                // and they are filled with NULLs
                prepend_nulls,
            };
        };

        /// Filters input data, only leaving rows that fit the condition.
        pub const Filter = struct {
            /// Input data source
            input: *DataNode,
            /// Condition to check
            condition: *ScalarNode,
        };

        /// Outputs rows all sources
        pub const UnionAll = struct {
            /// Sequence of inputs
            inputs: []DataNode,
        };

        /// Performs a join using a nested loop
        pub const NestedLoop = struct {
            op: Op,
            /// Left data source, scanned once
            lhs: *DataNode,
            /// Right data source, rescanned for each tuple from lhs
            rhs: *DataNode,
            /// Join condition
            cond: ?*ScalarNode,
            /// What kind of tuple should we output?
            output: OutputFormat,

            pub const Op = enum {
                cross, // No condition to check
                inner, // Only the tuples that pass the condition
                left, // Same as inner, plus left tuples with no match
                semi, // All left tuples that have at least one match
                anti_semi, // All left tuples that have no matches
            };

            pub const OutputFormat = enum {
                left_right,
                right_left,
                left_only,
            };
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
    dbtype: common.DBType, // Type of value it returns
    action: Action, // Type of node

    pub const Action = union(enum) {
        column: ColumnId, // Value from a column
        value: common.Value, // Constant value
        unary: Unary, // Unary operation
        binary: Binary, // Binary operation
        next_serial: ids.TableId, // Auto generate the next serial ID
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
