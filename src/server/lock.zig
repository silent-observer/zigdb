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
    waiting_modes: Mode.Set = .empty,
    condition: std.Io.Condition = .init,
    granted_list: std.DoublyLinkedList = .{},
    waiting_list: std.DoublyLinkedList = .{},

    const Holder = struct {
        thread: std.Thread.Id,
        mode: Mode,
        node: std.DoublyLinkedList.Node = .{},

        fn findInList(list: std.DoublyLinkedList, thread: std.Thread.Id) ?*Holder {
            var node = list.last;
            while (node) |n| {
                const h: *Holder = @fieldParentPtr("node", n);
                if (h.thread == thread)
                    return h;
                node = n.prev;
            }
            return null;
        }
    };
};

const ThreadInfo = struct {
    waiting_lock: ?Id = null,
    held_locks: std.SinglyLinkedList = .{},

    const HeldLock = struct {
        lock: Id,
        node: std.SinglyLinkedList.Node = .{},
    };
};

pub const Manager = struct {
    io: std.Io,
    mutex: std.Io.Mutex,
    locks: std.array_hash_map.Auto(Id, *Lock),
    lock_pool: std.heap.MemoryPoolExtra(
        Lock,
        .{ .growable = false },
    ),
    holder_pool: std.heap.MemoryPoolExtra(
        Lock.Holder,
        .{ .growable = false },
    ),
    threads: std.array_hash_map.Auto(std.Thread.Id, ThreadInfo),
    held_lock_pool: std.heap.MemoryPoolExtra(
        ThreadInfo.HeldLock,
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
        const holder_pool = std.heap.MemoryPoolExtra(
            Lock.Holder,
            .{ .growable = false },
        ).initCapacity(gpa, max_locks) catch common.oom();
        const held_lock_pool = std.heap.MemoryPoolExtra(
            ThreadInfo.HeldLock,
            .{ .growable = false },
        ).initCapacity(gpa, max_locks) catch common.oom();

        return .{
            .io = io,
            .mutex = .init,
            .locks = locks,
            .lock_pool = lock_pool,
            .holder_pool = holder_pool,
            .threads = threads,
            .held_lock_pool = held_lock_pool,
        };
    }

    pub fn deinit(self: *Manager, gpa: std.mem.Allocator) void {
        self.locks.deinit(gpa);
        self.holder_pool.deinit(gpa);
        self.lock_pool.deinit(gpa);
        self.held_lock_pool.deinit(gpa);
    }

    fn canGrant(l: *const Lock, mode: Mode, me: std.Thread.Id) bool {
        const possible_conflicts = Mode.conflicts.get(mode);
        if (possible_conflicts.intersectWith(l.granted_modes).eql(.empty)) {
            // Nothing conflicts, we can grant this!
            return true;
        }

        // Something conflicts, but maybe it's our own lock?
        var holder = l.granted_list.first;
        while (holder) |n| {
            const h: *Lock.Holder = @fieldParentPtr("node", n);
            if (possible_conflicts.contains(h.mode) and h.thread != me) {
                // Found someone else holding a conflicting lock, no luck...
                return false;
            }
            holder = n.next;
        }
        // Found no one, yay!
        return true;
    }

    fn rebuildWaitingSet(l: *Lock) void {
        l.waiting_modes = .empty;
        var holder = l.waiting_list.first;
        while (holder) |n| {
            const h: *Lock.Holder = @fieldParentPtr("node", n);
            l.waiting_modes.setPresent(h.mode, true);
            holder = n.next;
        }
    }

    fn rebuildGrantedSet(l: *Lock) void {
        l.granted_modes = .empty;
        var holder = l.granted_list.first;
        while (holder) |n| {
            const h: *Lock.Holder = @fieldParentPtr("node", n);
            l.granted_modes.setPresent(h.mode, true);
            holder = n.next;
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
            l.granted_modes.setPresent(mode, true);
            const new_holder = self.holder_pool.create(undefined) catch unreachable;
            new_holder.* = .{
                .thread = me,
                .mode = mode,
            };
            l.granted_list.prepend(&new_holder.node);

            {
                const ti = self.threads.getOrPutAssumeCapacity(me);
                if (!ti.found_existing)
                    ti.value_ptr.* = .{};

                const held_lock = self.held_lock_pool.create(undefined) catch unreachable;
                held_lock.* = .{ .lock = id };
                ti.value_ptr.held_locks.prepend(&held_lock.node);
            }
            return;
        } else {
            l.waiting_modes.setPresent(mode, true);
            const new_holder = self.holder_pool.create(undefined) catch unreachable;
            new_holder.* = .{
                .thread = me,
                .mode = mode,
            };
            l.waiting_list.prepend(&new_holder.node);

            {
                const ti = self.threads.getOrPutAssumeCapacity(me);
                if (!ti.found_existing)
                    ti.value_ptr.* = .{};
                ti.value_ptr.waiting_lock = id;
            }

            while (true) {
                try l.condition.wait(self.io, &self.mutex);
                const ti = self.threads.get(me).?;
                if (ti.waiting_lock == null)
                    break;
            }

            {
                const my_holder = Lock.Holder.findInList(l.waiting_list, me).?;
                l.waiting_list.remove(&my_holder.node);
                l.granted_list.prepend(&my_holder.node);

                l.granted_modes.setPresent(my_holder.mode, true);
                rebuildWaitingSet(l);
            }

            return;
        }
    }

    pub fn unlockAll(self: *Manager, me: std.Thread.Id) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        const ti = self.threads.get(me);
        if (ti == null) return;
        std.debug.assert(ti.?.waiting_lock == null);

        var held_lock = ti.?.held_locks.first;
        while (held_lock) |n| {
            held_lock = n.next;
            const hl: *ThreadInfo.HeldLock = @fieldParentPtr("node", n);

            const l = self.locks.get(hl.lock).?;
            var next_holder = l.granted_list.first;
            while (next_holder) |hn| {
                next_holder = hn.next;
                const h: *Lock.Holder = @fieldParentPtr("node", hn);
                if (h.thread == me) {
                    l.granted_list.remove(&h.node);
                    self.holder_pool.destroy(h);
                }
            }

            rebuildGrantedSet(l);

            if (l.waiting_list.last) |candidate_node| {
                const candidate: *Lock.Holder = @fieldParentPtr("node", candidate_node);
                if (canGrant(l, candidate.mode, candidate.thread)) {
                    self.threads.getPtr(candidate.thread).?.waiting_lock = null;
                    l.condition.broadcast(self.io);
                }
            }

            if (l.granted_list.first == null and l.waiting_list.first == null) {
                _ = self.locks.swapRemove(hl.lock);
                self.lock_pool.destroy(l);
            }

            self.held_lock_pool.destroy(hl);
        }

        _ = self.threads.swapRemove(me);
    }
};
