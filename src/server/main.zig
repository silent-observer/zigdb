const std = @import("std");

const zigdb = @import("zigdb");

fn handleConnection(
    io: std.Io,
    gpa: std.mem.Allocator,
    client_stream: std.Io.net.Stream,
    shared_state: zigdb.Session.Shared,
) void {
    defer client_stream.close(io);
    // Build thread-local catalog cache
    const catalog_cache = gpa.create(zigdb.catalog.Cache) catch zigdb.common.oom();
    catalog_cache.* = .init(
        gpa,
        1,
        shared_state.storage_cache,
    );

    const session = zigdb.Session{
        .gpa = gpa,
        .catalog_cache = catalog_cache,
        .db_id = 1,
        .current_tid = .virtual,
        .thread_id = std.Thread.getCurrentId(),
        .shared = shared_state,
        .sender = undefined,
    };

    var server = zigdb.Server.init(io, gpa, client_stream, session);
    defer server.deinit();
    server.loop() catch |e| {
        std.debug.print("Disconnected: {}\n", .{e});
    };
}

pub fn main(init: std.process.Init) !void {
    // Parse arguments
    var port: u16 = zigdb.common.network.default_port;
    var args = init.minimal.args.iterate();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-p")) {
            const port_str = args.next().?;
            port = try std.fmt.parseInt(u16, port_str, 10);
        }
    }

    std.debug.print("Accepting connections on port {}!\n", .{port});

    const listen_addr = try std.Io.net.IpAddress.parse(
        "0.0.0.0",
        port,
    );
    var tcp_server = try listen_addr.listen(init.io, .{});
    defer tcp_server.deinit(init.io);

    // Create the temporary data directory (for testing)
    try std.Io.Dir.cwd().createDirPath(init.io, "/tmp/datadir/logs");

    var logger = try zigdb.Logger.Shared.init(
        init.io,
        init.gpa,
        try std.Io.Dir.cwd().openDir(init.io, "/tmp/datadir/logs", .{}),
    );

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

    var variables_cache = try zigdb.VariablesCache.init(&storage_cache);

    {
        // Initialize and rebuild the catalog cache
        var catalog_cache = zigdb.catalog.Cache.init(init.gpa, 1, &storage_cache);
        defer catalog_cache.deinit(); // Don't forget to deinitialize

        // Build the actual catalog tables (this recreates the database from scratch)
        try catalog_cache.build();
    }

    var transaction_log = zigdb.transaction.Log.init(
        &storage_cache,
        &variables_cache,
        init.gpa,
    );
    defer transaction_log.deinit(init.gpa);

    var lock_manager = zigdb.lock.Manager.init(init.io, init.gpa);
    defer lock_manager.deinit(init.gpa);

    const shared_state = zigdb.Session.Shared{
        .storage_cache = &storage_cache,
        .transaction_log = &transaction_log,
        .lock_manager = &lock_manager,
        .variables_cache = &variables_cache,
        .logger = &logger,
    };

    //try catalog_cache.rebuild();

    while (true) {
        const client_stream = try tcp_server.accept(init.io);

        std.debug.print("Got connection from {f}!\n", .{client_stream.socket.address});

        const thread = try std.Thread.spawn(.{}, handleConnection, .{
            init.io,
            init.gpa,
            client_stream,
            shared_state,
        });
        thread.detach();
    }
}
