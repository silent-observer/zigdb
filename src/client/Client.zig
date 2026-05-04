const std = @import("std");
const common = @import("common");

const Client = @This();

gpa: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
descriptor_arena: std.heap.ArenaAllocator,

network_in_buffer: []u8,
network_out_buffer: []u8,
network_reader: std.Io.net.Stream.Reader,
network_writer: std.Io.net.Stream.Writer,

stdin_buffer: []u8,
stdin_reader: std.Io.File.Reader,
line_buffer: std.Io.Writer.Allocating,

last_descriptor: ?*common.TupleDescriptor,

pub fn init(io: std.Io, gpa: std.mem.Allocator, stream: std.Io.net.Stream) Client {
    const network_in_buffer = gpa.alloc(u8, 1024) catch common.oom();
    const network_out_buffer = gpa.alloc(u8, 1024) catch common.oom();
    const stdin_buffer = gpa.alloc(u8, 1024) catch common.oom();

    return Client{
        .gpa = gpa,
        .arena = .init(gpa),
        .descriptor_arena = .init(gpa),

        .network_in_buffer = network_in_buffer,
        .network_out_buffer = network_out_buffer,
        .stdin_buffer = stdin_buffer,

        .network_reader = stream.reader(io, network_in_buffer),
        .network_writer = stream.writer(io, network_out_buffer),
        .stdin_reader = std.Io.File.stdin().readerStreaming(io, stdin_buffer),
        .line_buffer = std.Io.Writer.Allocating.init(gpa),

        .last_descriptor = null,
    };
}

pub fn deinit(self: *Client) void {
    self.arena.deinit();
    self.descriptor_arena.deinit();
    self.gpa.free(self.network_in_buffer);
    self.gpa.free(self.network_out_buffer);
    self.gpa.free(self.stdin_buffer);
    self.line_buffer.deinit();
}

pub fn loop(self: *Client) !void {
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

fn handleMessage(self: *Client, m: common.network.Message) !bool {
    switch (m) {
        .err => std.debug.print("Error!\n", .{}),
        .success => {},
        .log => |l| std.debug.print("{s}\n", .{l}),
        .ready => {
            // Print prompt
            std.debug.print("> ", .{});
            // Read one line from stdin to line writer
            _ = try self.stdin_reader.interface.streamDelimiterEnding(
                &self.line_buffer.writer,
                '\n',
            );
            // Check if it's the exit command
            if (std.ascii.eqlIgnoreCase(self.line_buffer.written(), "exit"))
                return true;

            // Send the query
            const query_msg = common.network.Message{
                .query = self.line_buffer.written(),
            };
            try query_msg.write(&self.network_writer.interface);
            try self.network_writer.interface.flush();

            // Clear the command writer for the next command
            self.line_buffer.clearRetainingCapacity();
            // Skip newline
            self.stdin_reader.interface.toss(1);
        },
        .tuple_descriptor => |td| {
            _ = self.descriptor_arena.reset(.retain_capacity);
            self.last_descriptor =
                self.descriptor_arena.allocator()
                    .create(common.TupleDescriptor) catch common.oom();
            self.last_descriptor.?.* = td.clone(self.descriptor_arena.allocator());
        },
        .tuple => |tuple| {
            // We have to initialize the tuple descriptor!
            tuple.ptr.h.descr = self.last_descriptor.?;

            std.debug.print("{f}\n", .{tuple});
        },
        .query, .exit => unreachable,
    }
    return false;
}
