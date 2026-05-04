const std = @import("std");

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
    defer storage_cache.flush(true) catch {};

    // Initialize and rebuild the catalog cache
    var catalog_cache = zigdb.catalog.Cache.init(init.gpa, 1, &storage_cache);
    defer catalog_cache.deinit(); // Don't forget to deinitialize

    // Build the actual catalog tables (this recreates the database from scratch)
    try catalog_cache.build();

    var transaction_log = zigdb.transaction.Log.init(&storage_cache);

    //try catalog_cache.rebuild();

    std.debug.print("Accepting connections!\n", .{});

    const listen_addr = try std.Io.net.IpAddress.parse(
        "0.0.0.0",
        zigdb.common.network.default_port,
    );
    var tcp_server = try listen_addr.listen(init.io, .{});
    defer tcp_server.deinit(init.io);

    const client_stream = try tcp_server.accept(init.io);
    defer client_stream.close(init.io);

    std.debug.print("Got connection from {f}!\n", .{client_stream.socket.address});

    const session = zigdb.Session{
        .gpa = init.gpa,
        .catalog_cache = &catalog_cache,
        .storage_cache = &storage_cache,
        .transaction_log = &transaction_log,
    };

    var server = zigdb.Server.init(init.io, init.gpa, client_stream, session);
    defer server.deinit();
    try server.loop();
}
