const std = @import("std");
const t = @import("types.zig");
const MemTuple = @import("tuple.zig").MemTuple;
const oom = @import("utils.zig").oom;

pub const default_port = 17301;

pub const Message = union(Tag) {
    log: []const u8,
    query: []const u8,
    success: void,
    err: void,
    ready: void,
    tuple_descriptor: *const t.TupleDescriptor,
    tuple: MemTuple,
    exit: void,

    pub const Tag = enum(u8) {
        log = 'L',
        query = 'Q',
        success = 'S',
        err = 'E',
        ready = 'R',
        tuple_descriptor = 'D',
        tuple = 'T',
        exit = 'X',
    };

    fn calcSize(m: Message) usize {
        return switch (m) {
            .log => |l| l.len,
            .query => |q| q.len,
            .tuple => |tuple| tuple.size() - @sizeOf(MemTuple.Header),
            .tuple_descriptor => |td| size: {
                var total_size: usize = @sizeOf(u8) + @sizeOf(u16);
                for (td.attrs.items(.name)) |n| {
                    total_size += @sizeOf(u32) + @sizeOf(u8) + n.len;
                }
                break :size total_size;
            },
            .success, .err, .ready, .exit => 0,
        };
    }

    pub fn write(m: Message, w: *std.Io.Writer) !void {
        try w.writeByte(@intFromEnum(std.meta.activeTag(m)));
        const size = m.calcSize();
        try w.writeInt(u32, @intCast(size), .little);
        switch (m) {
            .log => |l| try w.writeAll(l),
            .query => |l| try w.writeAll(l),
            .tuple => |tup| {
                const ptr: [*]u8 = @ptrCast(&tup.ptr.tail);
                try w.writeAll(ptr[0..size]);
            },
            .tuple_descriptor => |td| {
                try w.writeByte(@intFromBool(td.has_extended));
                try w.writeInt(u16, @intCast(td.attrs.len), .little);
                const slice = td.attrs.slice();
                for (slice.items(.t), slice.items(.name)) |dbtype, name| {
                    try w.writeInt(u32, @intFromEnum(dbtype), .little);
                    try w.writeByte(@intCast(name.len));
                    try w.writeAll(name);
                }
            },
            .success, .err, .ready, .exit => {},
        }
    }

    pub const Error = error{MalformedMessage};

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
            .tuple => {
                const tuple = MemTuple.allocUnitialized(alloc, size + @sizeOf(MemTuple.Header));
                const byte_ptr: [*]u8 = @ptrCast(&tuple.ptr.tail);
                try r.readSliceAll(byte_ptr[0..size]);
                // WARNING: TupleDescriptor is left uninitialized!
                tuple.ptr.h.descr = undefined;
                return .{ .tuple = tuple };
            },
            .tuple_descriptor => {
                const has_extended = try r.takeByte() > 0;
                const attrs_len = try r.takeInt(u16, .little);
                var attrs = std.MultiArrayList(t.AttributeDescriptor)
                    .initCapacity(alloc, attrs_len) catch oom();
                for (0..attrs_len) |_| {
                    const dbtype: t.DBType = @enumFromInt(try r.takeInt(u32, .little));
                    const name_len = try r.takeByte();
                    const name = try r.readAlloc(alloc, name_len);
                    attrs.appendAssumeCapacity(t.AttributeDescriptor{
                        .t = dbtype,
                        .name = name,
                    });
                }
                const descr = alloc.create(t.TupleDescriptor) catch oom();
                descr.* = .{
                    .has_extended = has_extended,
                    .attrs = attrs,
                };
                return .{ .tuple_descriptor = descr };
            },
            .success => return .success,
            .err => return .err,
            .ready => return .ready,
            .exit => return .exit,
        }
    }

    pub const Sender = struct {
        writer: *std.Io.Writer,

        pub fn send(self: Sender, msg: Message) !void {
            // std.debug.print("Sent {}\n", .{msg});
            try msg.write(self.writer);
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
