const ids = @import("../ids.zig");

pub const Status = enum(u2) {
    in_progress = 0,
    committed = 1,
    aborted = 2,
    reserved = 3,
};
