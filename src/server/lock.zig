const std = @import("std");
const common = @import("common");
const ids = common.ids;

pub const Mode = enum {
    read,
    write,
    exclusive,

    const Set = std.enums.EnumSet(Mode);

    const conflicts: std.EnumArray(Mode, Mode.Set) = .init(.{
        .read = Mode.Set.initMany(&.{.exclusive}),
        .write = Mode.Set.initMany(&.{.exclusive}),
        .exclusive = Mode.Set.initFull(),
    });
};

pub const Id = union(enum) {
    table: ids.FullTableId,
};

const Lock = struct {
    granted_modes: Mode.Set = .empty,
    condition: std.Io.Condition = .init,
    granted_list: std.DoublyLinkedList = .{},
    waiting_list: std.DoublyLinkedList = .{},

    fn findGranted(lock: *Lock, thread: std.Thread.Id) ?*ThreadLock {
        var node = lock.granted_list.first;
        while (node) |n| {
            const h: *ThreadLock = @fieldParentPtr("per_lock_node", n);
            if (h.thread == thread)
                return h;
            node = n.next;
        }
        return null;
    }

    fn findWaiting(lock: *Lock, thread: std.Thread.Id) ?*Waiting {
        var node = lock.waiting_list.last;
        while (node) |n| {
            const h: *Waiting = @fieldParentPtr("node", n);
            if (h.thread == thread)
                return h;
            node = n.prev;
        }
        return null;
    }
};

const ThreadInfo = struct {
    waiting_lock: ?Id = null,
    granted_locks: std.DoublyLinkedList = .{},

    fn findGranted(thread: *ThreadInfo, lock: Id) ?*ThreadLock {
        var node = thread.granted_locks.first;
        while (node) |n| {
            const h: *ThreadLock = @fieldParentPtr("per_thread_node", n);
            if (h.lock == lock)
                return h;
            node = n.next;
        }
        return null;
    }
};

const ThreadLock = struct {
    lock: Id,
    thread: std.Thread.Id,
    modes: Mode.Set,
    per_lock_node: std.DoublyLinkedList.Node = .{},
    per_thread_node: std.DoublyLinkedList.Node = .{},
};

const Waiting = struct {
    thread: std.Thread.Id,
    mode: Mode,
    node: std.DoublyLinkedList.Node = .{},
};

pub const Manager = struct {
    io: std.Io,
    mutex: std.Io.Mutex,
    locks: std.array_hash_map.Auto(Id, *Lock),
    lock_pool: std.heap.MemoryPoolExtra(
        Lock,
        .{ .growable = false },
    ),
    thread_lock_pool: std.heap.MemoryPoolExtra(
        ThreadLock,
        .{ .growable = false },
    ),
    threads: std.array_hash_map.Auto(std.Thread.Id, ThreadInfo),
    waiting_pool: std.heap.MemoryPoolExtra(
        Waiting,
        .{ .growable = false },
    ),

    pub const max_locks = 1024;

    pub fn init(io: std.Io, gpa: std.mem.Allocator) Manager {
        var locks: std.array_hash_map.Auto(Id, *Lock) = .empty;
        locks.ensureTotalCapacity(gpa, max_locks) catch common.oom();

        var threads: std.array_hash_map.Auto(std.Thread.Id, ThreadInfo) = .empty;
        threads.ensureTotalCapacity(gpa, max_locks) catch common.oom();

        const lock_pool = std.heap.MemoryPoolExtra(
            Lock,
            .{ .growable = false },
        ).initCapacity(gpa, max_locks) catch common.oom();
        const thread_lock_pool = std.heap.MemoryPoolExtra(
            ThreadLock,
            .{ .growable = false },
        ).initCapacity(gpa, max_locks) catch common.oom();
        const waiting_pool = std.heap.MemoryPoolExtra(
            Waiting,
            .{ .growable = false },
        ).initCapacity(gpa, max_locks) catch common.oom();

        return .{
            .io = io,
            .mutex = .init,
            .locks = locks,
            .lock_pool = lock_pool,
            .thread_lock_pool = thread_lock_pool,
            .waiting_pool = waiting_pool,
            .threads = threads,
        };
    }

    pub fn deinit(self: *Manager, gpa: std.mem.Allocator) void {
        self.locks.deinit(gpa);
        self.lock_pool.deinit(gpa);
        self.thread_lock_pool.deinit(gpa);
        self.waiting_pool.deinit(gpa);
    }

    fn canGrant(l: *const Lock, mode: Mode, me: std.Thread.Id) bool {
        const possible_conflicts = Mode.conflicts.get(mode);
        if (possible_conflicts.intersectWith(l.granted_modes).eql(.empty)) {
            // Nothing conflicts, we can grant this!
            return true;
        }

        // Something conflicts, but maybe it's our own lock?
        var tl_node = l.granted_list.first;
        while (tl_node) |n| {
            const tl: *ThreadLock = @fieldParentPtr("per_lock_node", n);
            if (tl.thread != me and
                !possible_conflicts.intersectWith(tl.modes).eql(.empty))
            {
                // Found someone else holding a conflicting lock, no luck...
                return false;
            }
            tl_node = n.next;
        }
        // Found no one, yay!
        return true;
    }

    fn rebuildGrantedSet(l: *Lock) void {
        l.granted_modes = .empty;
        var tl_node = l.granted_list.first;
        while (tl_node) |n| {
            const tl: *ThreadLock = @fieldParentPtr("per_lock_node", n);
            l.granted_modes.setUnion(tl.modes);
            tl_node = n.next;
        }
    }

    fn grant(self: *Manager, l: *Lock, id: Id, mode: Mode, me: std.Thread.Id) void {
        l.granted_modes.setPresent(mode, true);
        if (l.findGranted(me)) |tl| {
            // We already have some locks here, just add a new one
            tl.modes.setPresent(mode, true);
            std.debug.print("{}: Additionally got {} lock on {}\n", .{ me, mode, id });
        } else {
            // We have to add a new entry to the lock list
            const tl = self.thread_lock_pool.create(undefined) catch unreachable;
            tl.* = .{
                .lock = id,
                .thread = me,
                .modes = .initOne(mode),
            };
            l.granted_list.prepend(&tl.per_lock_node);

            // Maybe we even have to make the thread entry
            const ti = self.threads.getOrPutAssumeCapacity(me);
            if (!ti.found_existing)
                ti.value_ptr.* = .{};

            ti.value_ptr.granted_locks.prepend(&tl.per_thread_node);
        }
    }

    pub fn lock(self: *Manager, id: Id, mode: Mode, me: std.Thread.Id) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        const r = self.locks.getOrPutAssumeCapacity(id);
        if (!r.found_existing) {
            const l = self.lock_pool.create(undefined) catch unreachable;
            l.* = .{};
            r.value_ptr.* = l;
        }
        const l = r.value_ptr.*;

        if (canGrant(l, mode, me)) {
            std.debug.print("{}: Immediately got {} lock on {}\n", .{ me, mode, id });
            self.grant(l, id, mode, me);
            return;
        } else {
            {
                const waiting = self.waiting_pool.create(undefined) catch unreachable;
                waiting.* = .{
                    .thread = me,
                    .mode = mode,
                };
                l.waiting_list.prepend(&waiting.node);
            }

            {
                const ti = self.threads.getOrPutAssumeCapacity(me);
                if (!ti.found_existing)
                    ti.value_ptr.* = .{};
                ti.value_ptr.waiting_lock = id;
            }

            std.debug.print("{}: Waiting for {} lock on {}\n", .{ me, mode, id });
            while (true) {
                try l.condition.wait(self.io, &self.mutex);
                const ti = self.threads.get(me).?;
                if (ti.waiting_lock == null)
                    break;
            }

            {
                const waiting = l.findWaiting(me).?;
                l.waiting_list.remove(&waiting.node);
            }

            std.debug.assert(canGrant(l, mode, me));
            std.debug.print("{}: Got {} lock on {}\n", .{ me, mode, id });
            self.grant(l, id, mode, me);
            return;
        }
    }

    pub fn unlockAll(self: *Manager, me: std.Thread.Id) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        const ti = self.threads.getPtr(me);
        if (ti == null) return;
        std.debug.assert(ti.?.waiting_lock == null);

        var tl_node = ti.?.granted_locks.first;
        while (tl_node) |n| {
            tl_node = n.next;
            const tl: *ThreadLock = @fieldParentPtr("per_thread_node", n);
            std.debug.print("{}: Starting to unlock {}\n", .{ me, tl.lock });

            const l = self.locks.get(tl.lock).?;

            ti.?.granted_locks.remove(&tl.per_thread_node);
            l.granted_list.remove(&tl.per_lock_node);

            rebuildGrantedSet(l);

            if (l.waiting_list.last) |candidate_node| {
                const candidate: *Waiting = @fieldParentPtr("node", candidate_node);
                if (canGrant(l, candidate.mode, candidate.thread)) {
                    std.debug.print("{}: Waking up {}\n", .{ me, candidate.thread });
                    self.threads.getPtr(candidate.thread).?.waiting_lock = null;
                    l.condition.broadcast(self.io);
                }
            }

            if (l.granted_list.first == null and l.waiting_list.first == null) {
                std.debug.print("{}: Removed lock {}\n", .{ me, tl.lock });
                _ = self.locks.swapRemove(tl.lock);
                self.lock_pool.destroy(l);
            }

            std.debug.print("{}: Done unlocking {}\n", .{ me, tl.lock });

            self.thread_lock_pool.destroy(tl);
        }

        _ = self.threads.swapRemove(me);
        std.debug.print("{}: Done unlocking\n", .{me});
    }
};
