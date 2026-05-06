//! Database client

const std = @import("std");
const common = @import("common");
const Client = @import("Client.zig");

pub fn main(init: std.process.Init) !void {
    std.debug.print("Testing!\n", .{});

    // Initialize the server address
    const server_addr = try std.Io.net.IpAddress.parse(
        "127.0.0.1",
        common.network.default_port,
    );
    // Start the connection
    const stream = try server_addr.connect(init.io, .{
        .mode = .stream,
        .protocol = .tcp,
    });
    defer stream.close(init.io);

    // Initialize the client
    var client = Client.init(init.io, init.gpa, stream);
    defer client.deinit();

    // Run the main loop
    try client.loop();
}
