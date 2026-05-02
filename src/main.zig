const std = @import("std");
const Io = std.Io;

const zigdb = @import("zigdb");

pub fn main(init: std.process.Init) !void {
    // Create the temporary data directory (for testing)
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

    // Initialize the catalog table descriptors
    zigdb.catalog.tables.init(init.arena.allocator());

    // Initialize the storage cache
    var storage_cache = zigdb.storage.Cache.init(
        init.gpa,
        init.io,
        "/tmp/datadir",
    );
    defer storage_cache.deinit(); // Don't forget to deinitialize

    // Initialize and rebuild the catalog cache
    var catalog_cache = zigdb.catalog.Cache.init(init.gpa, 1, &storage_cache);
    defer catalog_cache.deinit(); // Don't forget to deinitialize

    // Build the actual catalog tables (this recreates the database from scratch)
    try catalog_cache.build();

    var transaction_log = zigdb.TransactionLog.init(&storage_cache);

    //try catalog_cache.rebuild();

    // Create a stdin reader
    var stdin_buffer: [1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(init.io, &stdin_buffer);

    // Storage for the command line
    var line = std.Io.Writer.Allocating.init(init.gpa);
    defer line.deinit();

    while (true) {
        // Print prompt
        std.debug.print("> ", .{});
        // Read one line from stdin to line writer
        _ = try stdin_reader.interface.streamDelimiterEnding(&line.writer, '\n');
        // Check if it's the exit command
        if (std.ascii.eqlIgnoreCase(line.written(), "exit"))
            break;

        // Execute the query
        try zigdb.execute_stmt(
            init.io,
            init.gpa,
            &storage_cache,
            &catalog_cache,
            &transaction_log,
            line.written(),
        );
        try storage_cache.flush();

        // Clear the command writer for the next command
        line.clearRetainingCapacity();
        // Skip newline
        stdin_reader.interface.toss(1);
    }
}
