//! Server side of the network protocol.

const std = @import("std");
const common = @import("common");
const Session = @import("Session.zig");
const Logger = @import("Logger.zig");

const Server = @This();

/// Long-term allocator.
gpa: std.mem.Allocator,
/// Arena allocator that lives only for the lifetime of one message.
arena: std.heap.ArenaAllocator,
/// Session state of the connection.
session: Session,

network_in_buffer: []u8,
network_out_buffer: []u8,
network_reader: std.Io.net.Stream.Reader,
network_writer: std.Io.net.Stream.Writer,

/// Initialize the server side of the connection. Also sets the sender in session
pub fn init(
    io: std.Io,
    gpa: std.mem.Allocator,
    stream: std.Io.net.Stream,
    session: Session,
) *Server {
    const network_in_buffer = gpa.alloc(u8, 1024) catch common.oom();
    const network_out_buffer = gpa.alloc(u8, 1024) catch common.oom();

    const s = gpa.create(Server) catch common.oom();

    s.* = Server{
        .gpa = gpa,
        .arena = .init(gpa),
        .session = session,

        .network_in_buffer = network_in_buffer,
        .network_out_buffer = network_out_buffer,

        .network_reader = stream.reader(io, network_in_buffer),
        .network_writer = stream.writer(io, network_out_buffer),
    };

    s.session.sender = .{ .writer = &s.network_writer.interface };

    return s;
}

/// Deinitialize the server side.
pub fn deinit(self: *Server) void {
    self.arena.deinit();
    self.gpa.free(self.network_in_buffer);
    self.gpa.free(self.network_out_buffer);
    self.gpa.destroy(self);
}

/// Main message handling loop.
pub fn loop(self: *Server) !void {
    const ready_msg: common.network.Message = .ready;

    Logger.register(self.session.shared.logger, &self.session);
    defer Logger.unregister();

    try ready_msg.write(&self.network_writer.interface);
    try self.network_writer.interface.flush();

    while (true) {
        // Reset the per-message arena
        _ = self.arena.reset(.retain_capacity);

        // Read the next message from the connection
        const m = try common.network.Message.read(
            self.arena.allocator(),
            &self.network_reader.interface,
        );

        // Handle the message and possibly exit
        const exit = try self.handleMessage(m);
        if (exit)
            break;
    }
}

/// Handle one message received from the client
fn handleMessage(self: *Server, m: common.network.Message) !bool {
    switch (m) {
        // We got a new query to execute
        .query => |q| {
            try self.session.executeStmt(q);
            try self.session.sender.send(.ready);
        },
        // Time to close the connection
        .exit => return true,
        .err, .success, .log, .ready, .tuple_descriptor, .tuple => unreachable,
    }
    return false;
}
