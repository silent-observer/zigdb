//! This is a module operating with TOAST tables.
//! TOAST tables are special tables that contain sliced-up long strings
//! from the main table's data.
//!
//! Every TOAST table has 3 attributes:
//! - toast_id, which is a unique (serial) id for a toasted string
//! - toast_seq, which is the index of a chunk
//! - toast_data, which is the actual data of the chunk.
//!
//! So, for example, if the chunk size was 10, string
//! "Very long string that can't fit the main table data because it's so long"
//! would be represented like this in the TOAST table:
//!
//!  toast_id | toast_seq | toast_data
//! ----------+-----------+------------
//!      1234 |         0 | Very long
//!      1234 |         1 | string tha
//!      1234 |         2 | t can't fi
//!      1234 |         3 | t the main
//!      1234 |         4 |  table dat
//!      1234 |         5 | a because
//!      1234 |         6 | it's so lo
//!      1234 |         7 | ng
//!
//! The actual chunk size is chosen to be 1.5 KB, to fit approximately 5 chunks
//! into an 8 KB page.

const std = @import("std");
const common = @import("common");
const storage = @import("storage.zig");
const catalog = @import("catalog.zig");
const Session = @import("Session.zig");
const transaction = @import("transaction.zig");
const heap = @import("heap.zig");
const ids = common.ids;
const Text = common.Text;

/// Does this table have any attributes that might need to be toasted?
pub fn hasToastable(descr: *const common.TupleDescriptor) bool {
    for (descr.attrs.items) |att| {
        switch (att.t) {
            .long_text => return true,
            else => {},
        }
    }
    return false;
}

const max_chunk_size = 1536;

/// Construct a TOAST value from a given string
pub fn build(str: []const u8, toast_table_id: ids.TableId, alloc: std.mem.Allocator) !Text {
    // Small strings go directly into the raw Text
    if (str.len < 2 * 1024)
        return Text.makeRaw(str);

    const s = Session.get();
    // Get the toast table
    const toast_table = heap.Table.init(s.shared.storage_cache, .{
        .db = s.db_id,
        .table = toast_table_id,
    });
    const toast_id = try toast_table.getNextSerial();

    const descr = catalog.tables.descriptor(.toast_table);
    // Big strings have to be sliced up
    var offset: usize = 0;
    var count: u32 = 0;
    while (offset < str.len) {
        // max_chunk_size for most chunks, str.len - offset for the last one
        const chunk_size = @min(max_chunk_size, str.len - offset);
        const chunk = str[offset .. offset + chunk_size];

        // Construct the TOAST tuple
        var b = common.MemTuple.Builder.init(alloc, descr);
        b.push(u64, toast_id);
        b.push(u32, count);
        b.push(Text, Text.makeRaw(chunk));
        b.addExtended(.{
            .xmin = s.current_tid.real,
            .xmax = .invalid,
            .pos = undefined,
        });
        const tuple = b.finalize();
        defer tuple.deinit(alloc);

        // Add it to the TOAST table
        _ = try toast_table.addOneTuple(tuple, alloc);

        offset += max_chunk_size;
        count += 1;
    }
    return .{ .toast = .{
        .size = @intCast(str.len),
        .toast_id = toast_id,
        .toast_table_id = toast_table_id,
    } };
}

/// TOAST a Value, if it needs to be TOASTed. Only raw Text values need that.
pub fn toastValue(
    value: common.Value,
    toast_table_id: ids.TableId,
    alloc: std.mem.Allocator,
) !common.Value {
    return switch (value) {
        .text => |t| switch (t) {
            .raw => |str| common.Value{
                .text = try build(str, toast_table_id, alloc),
            },
            else => value,
        },
        else => value,
    };
}

/// Obtain a raw Text from a given one. If the input text was TOAST, then deTOAST it by gluing
/// together all the chunks
pub fn retrieve(text: Text, alloc: std.mem.Allocator, snapshot: *const transaction.Snapshot) !Text {
    switch (text) {
        .raw => return text,
        .toast => |toast| {
            const s = Session.get();
            // Preallocate data
            const data = alloc.alloc(u8, toast.size) catch common.oom();
            const descr = catalog.tables.descriptor(.toast_table);
            // Awful full scan of the table... I really need indexes here.
            var scan = try heap.Scanner.init(
                s.shared.storage_cache,
                .{
                    .db = s.db_id,
                    .table = toast.toast_table_id,
                },
                descr,
                snapshot,
            );
            while (try scan.next(alloc)) |tuple| {
                // Skip chunks that aren't ours
                if (tuple.get(u64, catalog.tables.index(.toast_id)) != toast.toast_id)
                    continue;
                // Get the sequence number and the data
                const seq = tuple.get(u32, catalog.tables.index(.toast_seq));
                const chunk = tuple.get(Text, catalog.tables.index(.toast_data)).raw;
                const offset = @as(usize, seq) * max_chunk_size;
                // Write the data to the correct place
                @memcpy(data[offset .. offset + chunk.len], chunk);
                defer tuple.deinit(alloc);
            }
            return Text.makeRaw(data);
        },
    }
}
