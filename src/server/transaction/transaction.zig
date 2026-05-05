const ids = @import("common").ids;

pub const Id = union(enum) {
    real: ids.RealTransactionId,
    virtual: void,
};

pub const Status = enum(u2) {
    in_progress = 0,
    committed = 1,
    aborted = 2,
    reserved = 3,
};

pub const ExplicitStatus = enum {
    inactive,
    active,
    broken,
};
