//! This is a network client for communication with the database server.

const std = @import("std");
const common = @import("common");
const Table = @import("Table.zig");

const Client = @This();

/// Long-term allocator.
gpa: std.mem.Allocator,
/// Arena allocator that lives only for the lifetime of one message.
arena: std.heap.ArenaAllocator,

network_in_buffer: []u8,
network_out_buffer: []u8,
network_reader: std.Io.net.Stream.Reader,
network_writer: std.Io.net.Stream.Writer,

stdin_buffer: []u8,
stdin_reader: std.Io.File.Reader,
/// Helper buffer for reading one line at a time
line_buffer: std.Io.Writer.Allocating,

/// Data for the table that is currently being assembled
table: Table,

/// Initialize a new client
pub fn init(io: std.Io, gpa: std.mem.Allocator, stream: std.Io.net.Stream) Client {
    const network_in_buffer = gpa.alloc(u8, 1024) catch common.oom();
    const network_out_buffer = gpa.alloc(u8, 1024) catch common.oom();
    const stdin_buffer = gpa.alloc(u8, 1024) catch common.oom();

    return Client{
        .gpa = gpa,
        .arena = .init(gpa),
        .table = .init(gpa),

        .network_in_buffer = network_in_buffer,
        .network_out_buffer = network_out_buffer,
        .stdin_buffer = stdin_buffer,

        .network_reader = stream.reader(io, network_in_buffer),
        .network_writer = stream.writer(io, network_out_buffer),
        .stdin_reader = std.Io.File.stdin().readerStreaming(io, stdin_buffer),
        .line_buffer = std.Io.Writer.Allocating.init(gpa),
    };
}

/// Deinitialize the client
pub fn deinit(self: *Client) void {
    self.arena.deinit();
    self.table.arena.deinit();
    self.gpa.free(self.network_in_buffer);
    self.gpa.free(self.network_out_buffer);
    self.gpa.free(self.stdin_buffer);
    self.line_buffer.deinit();
}

/// Main message handling loop
pub fn loop(self: *Client) !void {
    while (true) {
        // Reset the arena before each new message
        _ = self.arena.reset(.retain_capacity);

        // Read the message from network
        const m = try common.network.Message.read(
            self.arena.allocator(),
            &self.network_reader.interface,
        );

        // Handle it, and possibly exit
        const exit = try self.handleMessage(m);
        if (exit)
            break;
    }
}

/// Handle a single incoming message
fn handleMessage(self: *Client, m: common.network.Message) !bool {
    switch (m) {
        .err => std.debug.print("Error!\n", .{}),
        .success => if (self.table.descr != null) {
            std.debug.print("{f}", .{self.table});
        },
        // Received a log message from server
        .log => |l| std.debug.print("{s}\n", .{l}),
        // Ready to send a new query
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
        // Received a tuple descriptor for the next set of rows
        .tuple_descriptor => |td| {
            // Delete the previous one first
            self.table.reset();
            self.table.descr = td.clone(self.table.arena.allocator());
        },
        // Received a new tuple
        .tuple => |tuple| {
            // We have to initialize the tuple descriptor!
            tuple.ptr.h.descr = &self.table.descr.?;
            self.table.append(tuple.clone(self.table.arena.allocator()));
        },
        .query, .exit => unreachable,
    }
    return false;
}
