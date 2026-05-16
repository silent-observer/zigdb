//! Abstract Syntax Tree of SQL

const std = @import("std");
const common = @import("common");
const catalog = @import("../catalog.zig");
const DBType = common.DBType;
const Text = common.Text;

pub const Statement = union(enum) {
    select: Select,
    delete: Delete,
    insert_values: InsertValues,
    update: Update,
    create_table: CreateTable,
    drop_table: DropTable,
    truncate: Truncate,
    @"union": Union,
    begin: void,
    commit: void,
    rollback: void,
    show_tables: void,
    show_table: Name,
    err: void,

    pub const Select = struct {
        columns: []ColumnExpression,
        source: *DataSource,
        where: ?*Expression,
        t: ?*const common.TupleDescriptor = null,

        pub const ColumnExpression = union(enum) {
            normal: Normal,
            star: void,

            pub const Normal = struct {
                expr: *Expression,
                alias: ?Name,
            };
        };
    };

    pub const Delete = struct {
        name: Name,
        where: ?*Expression,
    };

    pub const InsertValues = struct {
        name: Name,
        columns: []Name,
        values: *DataSource,
    };

    pub const Update = struct {
        name: Name,
        clauses: []SetClause,
        where: ?*Expression,

        pub const SetClause = struct {
            column: Name,
            expr: *Expression,
        };
    };

    pub const CreateTable = struct {
        name: Name,
        columns: []ColumnDefinition,

        pub const ColumnDefinition = struct {
            name: Name,
            col_type: DBType,
        };
    };

    pub const DropTable = struct {
        name: Name,
    };

    pub const Truncate = struct {
        name: Name,
    };

    pub const Union = struct {
        stmts: []Statement,
    };
};

pub const Expression = struct {
    t: ?common.DBType = null,
    u: union(enum) {
        variable: Variable,
        unary: Unary,
        binary: Binary,
        func: FunctionCall,
        value: common.Value,
        err: void,
    },

    pub const err = Expression{ .u = .err };

    pub const Variable = struct {
        name: Name,
        table: ?Name = null,
    };

    pub const Binary = struct {
        op: Op,
        left: *Expression,
        right: *Expression,

        pub const Op = enum {
            add,
            sub,
            mul,
            div,
            eq,
            ne,
            gt,
            lt,
            ge,
            le,
            @"and",
            @"or",
        };
    };

    pub const Unary = struct {
        op: Op,
        expr: *Expression,

        pub const Op = enum {
            neg,
            not,
            null,
            not_null,
        };
    };

    pub const FunctionCall = struct {
        func: catalog.functions.ScalarFunctionId,
        inputs: []Expression,
    };
};

pub const DataSource = struct {
    t: ?*const common.TupleDescriptor = null,
    alias: ?Name = null,
    u: union(enum) {
        table: Table,
        join: Join,
        values: Values,
        func: FunctionCall,
        err: void,
    },

    pub const err = DataSource{ .u = .err };

    pub const Table = struct {
        name: Name,
    };

    pub const Join = struct {
        kind: Kind,
        lhs: *DataSource,
        rhs: *DataSource,
        cond: ?*Expression,

        pub const Kind = enum {
            cross,
            inner,
            left,
            right,
            full,
        };
    };

    pub const Values = struct {
        data: [][]Expression,
    };

    pub const FunctionCall = struct {
        func: catalog.functions.SetReturningFunctionId,
        inputs: []Expression,
    };
};

pub const Name = struct {
    text: []const u8,
    id: ?common.ids.ObjectId = null,
};
