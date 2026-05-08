//! Abstract Syntax Tree of SQL

const std = @import("std");
const DBType = @import("common").DBType;

pub const Statement = union(enum) {
    select: Select,
    delete: Delete,
    insert_values: InsertValues,
    update: Update,
    create_table: CreateTable,
    drop_table: DropTable,
    truncate: Truncate,
    begin: void,
    commit: void,
    rollback: void,
    err: void,

    pub const Select = struct {
        columns: []Expression,
        sources: []DataSource,
        where: ?*Expression,
    };

    pub const Delete = struct {
        name: Name,
        where: ?*Expression,
    };

    pub const InsertValues = struct {
        name: Name,
        columns: []Name,
        values: []ValueList,
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
};

pub const ValueList = struct {
    columns: []Expression,
};

pub const Expression = union(enum) {
    variable: Name,
    unary: Unary,
    binary: Binary,
    integer: i64,
    string: []const u8,
    bool: bool,
    err: void,

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
        };
    };
};

pub const DataSource = union(enum) {
    table: Table,
    err: void,

    pub const Table = struct {
        name: Name,
    };
};

pub const Name = []const u8;
