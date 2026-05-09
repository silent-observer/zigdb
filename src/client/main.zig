//! Database client

const std = @import("std");
const common = @import("common");
const Client = @import("Client.zig");

pub fn main(init: std.process.Init) !void {
    // Parse arguments
    var config = Client.Config{};
    var args = init.minimal.args.iterate();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--no-prompt"))
            config.prompt = false;
        if (std.mem.eql(u8, arg, "-p")) {
            const port = args.next().?;
            config.port = try std.fmt.parseInt(u16, port, 10);
        }
    }

    // Initialize the server address
    const server_addr = try std.Io.net.IpAddress.parse(
        "127.0.0.1",
        config.port,
    );
    // Start the connection
    const stream = try server_addr.connect(init.io, .{
        .mode = .stream,
        .protocol = .tcp,
    });
    defer stream.close(init.io);

    // Initialize the client
    var client = Client.init(init.io, init.gpa, stream, config);
    defer client.deinit();

    // Run the main loop
    try client.loop();
}
