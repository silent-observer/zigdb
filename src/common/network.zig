//! Description of the network protocol used for communcation between
//! the server and clients.
//!
//! This is how the communication between server and client generally proceeds:
//! Server: ready (client can send the next query)
//! Client: query (client sends an SQL query to execute)
//! Server: log (server sends text messages that can correspond to logs, warnings or errors)
//!         ...
//!         log
//! Server: tuple_descriptor (server sends the tuple descriptor for the resulting data)
//! Server: tuple (server sends tuples from the result data one by one)
//!         ...
//!         tuple
//! Server: success/err (server sends a success or error message at the end)
//! Server: ready (server is ready for the next query)
//! Client: ...
//!
//! Queries that don't return data don't send "tuple_descriptor" and "tuple" messages,
//! and instead immediately send success/err on completion.
//! Also, the client can send "exit" message instead of a query to close the connection.

const std = @import("std");
const types = @import("types.zig");
const DBType = types.DBType;
const TupleDescriptor = types.TupleDescriptor;
const AttributeDescriptor = types.AttributeDescriptor;
const tuple = @import("tuple.zig");
const MemTuple = tuple.MemTuple;
const CompactTuple = tuple.CompactTuple;
const oom = @import("utils.zig").oom;

/// Default port for the server
pub const default_port = 17301;

/// Message that can be sent through the network.
///
/// Each message has the following format:
/// - tag (1 byte) - the type of the message
/// - size (4 bytes) - how many bytes of data there are
/// - data ("size" bytes) - the actual data, the exact contents depend on the tag
///
/// "err", "ready" and "exit" messages have no data, so their size is always 0.
/// "success", "log" and "query" messages have raw text as their data.
/// "tuple" message data is the same format as MemTuple, but without the TupleDescriptor
/// pointer in the header.
///
/// "tuple_descriptor" message has the following format:
/// - tag = 'D' (1 byte) - the type of the message
/// - size (4 bytes) - how many bytes of data there are
/// - has_extended (1 byte) - whether or not the tuples have extended fields
/// - attrs count (2 bytes) - number of attributes
/// - 0th attr type (4 bytes) - type of attr 0
/// - 0th attr name length (1 byte) - length of attr 0 name
/// - 0th attr name (? bytes) - the name itself of attr 0
/// - 1st attr type (4 bytes)
///   ...
/// - Nth attr name (? bytes)
///
/// All integers in the messages are little-endian
pub const Message = union(Tag) {
    log: []const u8,
    query: []const u8,
    success: []const u8,
    err: void,
    incomplete: void,
    ready: void,
    tuple_descriptor: *const TupleDescriptor,
    tuple: NetworkTuple,
    exit: void,

    pub const Tag = enum(u8) {
        log = 'L',
        query = 'Q',
        success = 'S',
        err = 'E',
        incomplete = 'I',
        ready = 'R',
        tuple_descriptor = 'D',
        tuple = 'T',
        exit = 'X',
    };

    const NetworkTuple = CompactTuple(void);
    pub fn makeTuple(t: MemTuple, alloc: std.mem.Allocator) Message {
        return Message{
            .tuple = NetworkTuple.compact(
                .{
                    .header = {},
                    .values = t.values,
                },
                t.descr,
                alloc,
            ),
        };
    }

    pub fn unmakeTuple(m: Message, descr: *const TupleDescriptor, alloc: std.mem.Allocator) !MemTuple {
        std.debug.assert(m == .tuple);
        const data = try m.tuple.uncompact(descr, alloc);
        return .{
            .descr = descr,
            .ext = null,
            .values = data.values,
        };
    }

    /// Calculate the size of data for the message
    fn calcSize(m: Message) usize {
        return switch (m) {
            .log => |l| l.len,
            .query => |q| q.len,
            .success => |s| s.len,
            .tuple => |t| t.data.len,
            .tuple_descriptor => |td| size: {
                var total_size: usize = @sizeOf(u8) + @sizeOf(u16);
                for (td.attrs.items) |att| {
                    total_size +=
                        @sizeOf(u8) + att.t.writeLen() +
                        @sizeOf(u8) + att.name.len;
                }
                break :size total_size;
            },
            .err, .ready, .exit, .incomplete => 0,
        };
    }

    /// Serialize the message into bytes and write them into a Writer
    pub fn write(m: Message, w: *std.Io.Writer) !void {
        try w.writeByte(@intFromEnum(std.meta.activeTag(m)));
        const size = m.calcSize();
        try w.writeInt(u32, @intCast(size), .little);
        switch (m) {
            .log => |l| try w.writeAll(l),
            .query => |l| try w.writeAll(l),
            .success => |l| try w.writeAll(l),
            .tuple => |tup| try w.writeAll(tup.data),
            .tuple_descriptor => |td| {
                try w.writeByte(@intFromBool(td.has_extended));
                try w.writeInt(u16, @intCast(td.len()), .little);
                for (td.attrs.items) |att| {
                    try w.writeByte(@intCast(att.t.writeLen()));
                    try att.t.write(w);
                    try w.writeByte(@intCast(att.name.len));
                    try w.writeAll(att.name);
                }
            },
            .err, .ready, .exit, .incomplete => {},
        }
    }

    pub const Error = error{MalformedMessage};

    /// Read bytes from a Reader and deserialize them into a Message
    pub fn read(alloc: std.mem.Allocator, r: *std.Io.Reader) !Message {
        const tag = std.enums.fromInt(Tag, try r.takeByte()) orelse
            return Error.MalformedMessage;
        const size = try r.takeInt(u32, .little);
        switch (tag) {
            .log => return .{
                .log = try r.readAlloc(alloc, size),
            },
            .query => return .{
                .query = try r.readAlloc(alloc, size),
            },
            .success => return .{
                .success = try r.readAlloc(alloc, size),
            },
            .tuple => return .{
                .tuple = .{
                    .data = try r.readAlloc(alloc, size),
                },
            },
            .tuple_descriptor => {
                const has_extended = try r.takeByte() > 0;
                const attrs_len = try r.takeInt(u16, .little);
                var attrs = std.ArrayList(AttributeDescriptor)
                    .initCapacity(alloc, attrs_len) catch oom();
                for (0..attrs_len) |_| {
                    const dbtype_len = try r.takeByte();
                    const dbtype_buf = try r.take(dbtype_len);
                    var dbtype_reader = std.Io.Reader.fixed(dbtype_buf);
                    const dbtype = try DBType.read(&dbtype_reader);
                    const name_len = try r.takeByte();
                    const name = try r.readAlloc(alloc, name_len);
                    attrs.appendAssumeCapacity(AttributeDescriptor{
                        .t = dbtype,
                        .name = name,
                        .table_name = "",
                    });
                }
                const descr = alloc.create(TupleDescriptor) catch oom();
                descr.* = .{
                    .has_extended = has_extended,
                    .attrs = attrs,
                };
                return .{ .tuple_descriptor = descr };
            },
            .err => return .err,
            .incomplete => return .incomplete,
            .ready => return .ready,
            .exit => return .exit,
        }
    }

    /// Convenience struct to easily send messages through the network
    pub const Sender = struct {
        writer: *std.Io.Writer,

        pub fn send(self: Sender, msg: Message) !void {
            try msg.write(self.writer);
            // Don't forget to flush or the message won't get sent
            try self.writer.flush();
        }

        pub fn log(
            self: Sender,
            alloc: std.mem.Allocator,
            comptime fmt: []const u8,
            args: anytype,
        ) !void {
            const text = std.fmt.allocPrint(alloc, fmt, args) catch oom();
            defer alloc.free(text);
            try self.send(.{ .log = text });
        }
    };
};
