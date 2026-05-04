const std = @import("std");
const common = @import("common");
const Client = @import("Client.zig");

pub fn main(init: std.process.Init) !void {
    std.debug.print("Testing!\n", .{});

    const server_addr = try std.Io.net.IpAddress.parse(
        "127.0.0.1",
        common.network.default_port,
    );
    const stream = try server_addr.connect(init.io, .{
        .mode = .stream,
        .protocol = .tcp,
    });
    defer stream.close(init.io);

    var client = Client.init(init.io, init.gpa, stream);
    defer client.deinit();

    try client.loop();
}
