const ids = @import("common").ids;

/// Transactions can be real, represented by real IDs, or virtual.
/// Virtual transactions can be used only for reading and cannot write anything.
/// Only real transactions are recorded in the database.
pub const Id = union(enum) {
    real: ids.RealTransactionId,
    virtual: void,

    pub fn jsonStringify(self: Id, jws: anytype) !void {
        switch (self) {
            .virtual => try jws.write("virtual"),
            .real => |r| try jws.write(r.v),
        }
    }
};

/// Status of some transaction
pub const Status = enum(u2) {
    in_progress = 0,
    committed = 1,
    aborted = 2,
    reserved = 3,
};

/// Status of an explicitly started transaction
pub const ExplicitStatus = enum {
    inactive,
    active,
    broken,
};
