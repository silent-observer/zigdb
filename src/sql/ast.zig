//! Abstract Syntax Tree of SQL

const std = @import("std");
const DBType = @import("../data/types.zig").DBType;

pub const Statement = union(enum) {
    select: Select,
    insert_values: InsertValues,
    create_table: CreateTable,
    drop_table: DropTable,
    truncate: Truncate,
    err: void,

    pub const Select = struct {
        columns: std.ArrayList(Expression),
        sources: std.ArrayList(DataSource),
        where: ?*Expression,
    };

    pub const InsertValues = struct {
        name: Name,
        columns: std.ArrayList(Name),
        values: std.ArrayList(ValueList),
    };

    pub const CreateTable = struct {
        name: Name,
        columns: std.ArrayList(ColumnDefinition),

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
    columns: std.ArrayList(Expression),
};

pub const Expression = union(enum) {
    variable: Name,
    unary: Unary,
    binary: Binary,
    integer: i64,
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
