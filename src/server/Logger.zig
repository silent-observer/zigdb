//! Universal logger that sends logs both to client and log file on server.

const std = @import("std");
const zeit = @import("zeit");
const common = @import("common");
const Session = @import("Session.zig");
const transaction = @import("transaction.zig");

const Logger = @This();

/// We have a thread-local global Logger instance
threadlocal var local_logger: ?Logger = null;

/// Level of the log message, the higher the more severe.
pub const Level = enum {
    debug,
    log,
    notice,
    warning,
    err,

    /// Check if the message passes a threshold
    fn shouldLog(self: Level, threshold: Level) bool {
        return @intFromEnum(self) >= @intFromEnum(threshold);
    }
};

/// Client-readable error level names.
const level_names: std.enums.EnumArray(Level, []const u8) = .init(.{
    .debug = "DEBUG",
    .log = "LOG",
    .notice = "NOTICE",
    .warning = "WARNING",
    .err = "ERROR",
});

/// Shared data for logger
pub const Shared = struct {
    /// Per-log arena.
    arena: std.heap.ArenaAllocator,
    /// Io instance.
    io: std.Io,
    /// Mutex for synchronization (since Logger is shared).
    mutex: std.Io.Mutex,
    /// Log file on server side.
    log_file: std.Io.File,
    /// Buffer for writing logs to file.
    log_buffer: []const u8,
    /// Writer for log_file.
    server_writer: std.Io.File.Writer,

    /// Initialize the shared part of the logger.
    pub fn init(io: std.Io, gpa: std.mem.Allocator, log_dir: std.Io.Dir) !Logger.Shared {
        var buf: [256]u8 = undefined;
        const now = try zeit.instant(io, .{});
        var writer = std.Io.Writer.fixed(&buf);
        const dt = now.time();
        // Log file name contains the date
        try dt.strftime(&writer, "%Y_%m_%d_%H_%M_%S.jsonl");
        const path = writer.buffered();

        const log_buffer = gpa.alloc(u8, 1024) catch common.oom();
        const log_file = try log_dir.createFile(
            io,
            path,
            .{ .truncate = false },
        );

        return .{
            .arena = .init(gpa),
            .io = io,
            .mutex = .init,
            .log_file = log_file,
            .log_buffer = log_buffer,
            .server_writer = log_file.writer(io, log_buffer),
        };
    }

    /// Deinitialize the shared part of the logger.
    pub fn deinit(l: *Logger.Shared, gpa: std.mem.Allocator) void {
        l.arena.deinit();
        l.log_file.close(l.io);
        gpa.free(l.log_buffer);
    }
};

/// Shared data
shared: *Shared,
/// Threshold for server-logged messages.
server_level: Level = .log,
/// Threshold for client-logged messages.
client_level: Level = .notice,

/// Initialize the thread-local part of the logger.
pub fn register(shared: *Logger.Shared) void {
    local_logger = .{ .shared = shared };
}

/// Remove the thread-local logger
pub fn unregister() void {
    local_logger = null;
}

/// Print a single log message with payload.
pub fn printPayload(level: Level, comptime fmt: []const u8, args: anytype, payload: anytype) void {
    // Fast return path when nothing should be logged
    if (!level.shouldLog(local_logger.?.client_level) and
        !level.shouldLog(local_logger.?.server_level))
        return;

    const l = local_logger.?.shared;
    const s = Session.get();
    // Take the mutex to avoid concurrent logging
    l.mutex.lock(l.io) catch return;
    defer l.mutex.unlock(l.io);
    // Reset the arena for this log line
    _ = l.arena.reset(.retain_capacity);

    // Client logging
    if (level.shouldLog(local_logger.?.client_level)) {
        s.sender.log(
            l.arena.allocator(),
            "{s}: " ++ fmt,
            .{level_names.get(level)} ++ args,
        ) catch {};
    }

    // Server logging
    if (level.shouldLog(local_logger.?.server_level)) {
        const message = std.fmt.allocPrint(l.arena.allocator(), fmt, args) catch common.oom();

        // Construct the timestamp
        const now = zeit.instant(l.io, .{}) catch return;
        var writer = std.Io.Writer.Allocating.init(l.arena.allocator());
        const dt = now.time();
        dt.strftime(&writer.writer, "%Y-%m-%dT%H:%M:%S.%fZ") catch common.oom();

        // Format log as JSON
        const base_with_payload = if (@TypeOf(payload) != @TypeOf(null)) .{
            .timestamp = writer.written(),
            .level = level_names.get(level),
            .message = message,
            .db = s.db_id,
            .thread = s.thread_id,
            .tid = s.current_tid,
            .payload = payload,
        } else .{
            .timestamp = writer.written(),
            .level = level_names.get(level),
            .message = message,
            .db = s.db_id,
            .thread = s.thread_id,
            .tid = s.current_tid,
        };
        const formatter = std.json.fmt(base_with_payload, .{});

        // Write newline-separated JSON
        l.server_writer.interface.print("{f}\n", .{formatter}) catch {
            l.server_writer.interface.print("Error durring logging!\n", .{}) catch {};
        };
        l.server_writer.interface.flush() catch return;
    }
}

/// Print a single log message.
pub fn print(level: Level, comptime fmt: []const u8, args: anytype) void {
    printPayload(level, fmt, args, null);
}

/// Convenience function for DEBUG log level.
pub fn debug(comptime fmt: []const u8, args: anytype) void {
    print(.debug, fmt, args);
}

/// Convenience function for LOG log level.
pub fn log(comptime fmt: []const u8, args: anytype) void {
    print(.log, fmt, args);
}

/// Convenience function for NOTICE log level.
pub fn note(comptime fmt: []const u8, args: anytype) void {
    print(.notice, fmt, args);
}

/// Convenience function for WARNING log level.
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    print(.warning, fmt, args);
}

/// Convenience function for ERROR log level.
pub fn err(comptime fmt: []const u8, args: anytype) void {
    print(.err, fmt, args);
}
