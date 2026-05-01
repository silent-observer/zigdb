const std = @import("std");
const Io = std.Io;

const zigdb = @import("zigdb");

pub fn main(init: std.process.Init) !void {
    std.Io.Dir.createDirAbsolute(
        init.io,
        "/tmp/datadir",
        std.Io.File.Permissions.default_dir,
    ) catch |err| {
        switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        }
    };

    zigdb.catalog.tables.init(init.arena.allocator());

    var storage_cache = zigdb.storage.Cache.init(
        init.gpa,
        init.io,
        "/tmp/datadir",
    );
    defer storage_cache.deinit();

    try zigdb.catalog.Cache.build(init.gpa, &storage_cache, 1);

    var catalog_cache = zigdb.catalog.Cache.init(init.gpa, 1);
    defer catalog_cache.deinit();
    try catalog_cache.rebuild(&storage_cache);

    var stdin_buffer: [1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(init.io, &stdin_buffer);

    var line = std.Io.Writer.Allocating.init(init.gpa);

    while (true) {
        std.debug.print("> ", .{});
        _ = try stdin_reader.interface.streamDelimiterEnding(&line.writer, '\n');
        if (std.ascii.eqlIgnoreCase(line.written(), "exit"))
            break;

        try zigdb.execute_stmt(
            init.io,
            init.gpa,
            &storage_cache,
            &catalog_cache,
            line.written(),
        );

        line.clearRetainingCapacity();
        stdin_reader.interface.toss(1);
    }
}
