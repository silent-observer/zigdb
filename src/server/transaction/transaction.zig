const ids = @import("common").ids;

/// Status of some transaction
pub const Status = enum(u2) {
    in_progress = 0,
    committed = 1,
    aborted = 2,
    reserved = 3,
};
