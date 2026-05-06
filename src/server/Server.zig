const std = @import("std");
const common = @import("common");
const Session = @import("Session.zig");

const Server = @This();

gpa: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
session: Session,

network_in_buffer: []u8,
network_out_buffer: []u8,
network_reader: std.Io.net.Stream.Reader,
network_writer: std.Io.net.Stream.Writer,

pub fn init(
    io: std.Io,
    gpa: std.mem.Allocator,
    stream: std.Io.net.Stream,
    session: Session,
) Server {
    const network_in_buffer = gpa.alloc(u8, 1024) catch common.oom();
    const network_out_buffer = gpa.alloc(u8, 1024) catch common.oom();

    return Server{
        .gpa = gpa,
        .arena = .init(gpa),
        .session = session,

        .network_in_buffer = network_in_buffer,
        .network_out_buffer = network_out_buffer,

        .network_reader = stream.reader(io, network_in_buffer),
        .network_writer = stream.writer(io, network_out_buffer),
    };
}

pub fn deinit(self: *Server) void {
    self.arena.deinit();
    self.gpa.free(self.network_in_buffer);
    self.gpa.free(self.network_out_buffer);
}

pub fn loop(self: *Server) !void {
    const ready_msg: common.network.Message = .ready;
    try ready_msg.write(&self.network_writer.interface);
    try self.network_writer.interface.flush();

    while (true) {
        _ = self.arena.reset(.retain_capacity);

        const m = try common.network.Message.read(
            self.arena.allocator(),
            &self.network_reader.interface,
        );

        const exit = try self.handleMessage(m);
        if (exit)
            break;
    }
}

fn handleMessage(self: *Server, m: common.network.Message) !bool {
    // std.debug.print("Got {}\n", .{m});
    switch (m) {
        .query => |q| {
            const sender = common.network.Message.Sender{
                .writer = &self.network_writer.interface,
            };

            try self.session.execute_stmt(q, sender);
            try sender.send(.ready);
        },
        .exit => return true,
        .err, .success, .log, .ready, .tuple_descriptor, .tuple => unreachable,
    }
    return false;
}
