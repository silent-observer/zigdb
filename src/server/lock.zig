//! This contains the locking mechanism to ensure safe concurrency.
//! This is shared between all threads, so great care should be taken
//! to avoid data races.

const std = @import("std");
const common = @import("common");
const ids = common.ids;

/// The type of lock to be taken.
pub const Mode = enum {
    read, // SELECT
    write, // INSERT, DELETE, UPDATE etc.
    exclusive, // TRUNCATE

    /// A set of multiple lock modes (implemented as a bitset).
    const Set = std.enums.EnumSet(Mode);

    /// Which lock modes conflict with each other.
    const conflicts: std.EnumArray(Mode, Mode.Set) = .init(.{
        .read = Mode.Set.initMany(&.{.exclusive}),
        .write = Mode.Set.initMany(&.{.exclusive}),
        .exclusive = Mode.Set.initFull(),
    });
};

/// The object being locked. Currently only tables are supported.
pub const Id = union(enum) {
    table: ids.FullTableId,
};

/// Information about a single locked object.
const Lock = struct {
    /// Which lock modes are currently granted for this object.
    granted_modes: Mode.Set = .empty,
    /// Condition variable to wake up waiting threads.
    condition: std.Io.Condition = .init,
    /// List of ThreadLock structures, representing all threads that
    /// currently have locks on this object.
    granted_list: std.DoublyLinkedList = .{},
    /// List of Waiting structures, representing all threads that
    /// are currently waiting to take a lock on this object.
    waiting_list: std.DoublyLinkedList = .{},

    /// Find the thread in the granted list.
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

    /// Find the thread in the waiting list.
    fn findWaiting(lock: *Lock, thread: std.Thread.Id) ?*Waiting {
        // We are going backwards, since most likely we're looking
        // for the last node here.
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

/// Information about a single thread that is currently holding locks.
const ThreadInfo = struct {
    /// Is the thread waiting to get some lock?
    waiting_lock: ?Id = null,
    /// The list of ThreadLock structures representing all locks this
    /// thread has.
    granted_locks: std.DoublyLinkedList = .{},

    /// Find a lock in the granted list.
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

/// Node representing a thread + lock pair.
/// Each node represents a thread that is holding a lock
/// with a given set of modes.
///
/// Each of these nodes is actually placed in two linked lists
/// at once: one for its thread, and one for its locked object.
/// Visually, Lock, ThreadInfo and ThreadLock for this kind of
/// graph in memory, with vertial links representing per-thread
/// lists, and horizontal links representing per-lock lists:
///
/// ```
///              +-------+   +-------+   +-------+
///              | Thr 1 |   | Thr 2 |   | Thr 3 |
///              +-------+   +-------+   +-------+
///                  |           |           |
/// +--------+   +-------+       |       +-------+
/// | Lock A |<->| TL A1 |<------|------>| TL A3 |
/// +--------+   +-------+       |       +-------+
///                  |           |           |
/// +--------+       |       +-------+       |
/// | Lock B |<------|------>| TL B2 |       |
/// +--------+       |       +-------+       |
///                  |           |           |
/// +--------+   +-------+   +-------+   +-------+
/// | Lock C |<->| TL C1 |<->| TL C2 |<->| TL C3 |
/// +--------+   +-------+   +-------+   +-------+
/// ```
const ThreadLock = struct {
    lock: Id, // Lock this node belongs to
    thread: std.Thread.Id, // Thread this node belongs to
    modes: Mode.Set, // Lock modes that are taken
    // Node for list inside Lock structure
    per_lock_node: std.DoublyLinkedList.Node = .{},
    // Node for list inside ThreadInfo structure
    per_thread_node: std.DoublyLinkedList.Node = .{},
};

/// Node representing a thread waiting to take a lock with some specific mode.
/// These nodes are linked into a doubly-linked list, forming a queue,
/// but only a single list each, unlike ThreadInfo.
/// There can only be at most one Waiting node for every thread.
const Waiting = struct {
    thread: std.Thread.Id, // Thread this node belongs to
    mode: Mode, // Lock mode it wants to take
    // Node for list inside Lock structure
    node: std.DoublyLinkedList.Node = .{},
};

/// The main manager object. All locking/unlocking should be
/// done through this.
pub const Manager = struct {
    /// Io instance for mutexes
    io: std.Io,
    /// Global mutex for the whole manager
    mutex: std.Io.Mutex,
    /// Hash map of Lock structures, keyed by their Ids.
    /// The Locks themselves are stored in lock_pool.
    locks: std.array_hash_map.Auto(Id, *Lock),
    /// Pool of Lock structures for fast allocation.
    lock_pool: std.heap.MemoryPoolExtra(
        Lock,
        .{ .growable = false },
    ),
    /// Pool of ThreadLock structures for fast allocation.
    thread_lock_pool: std.heap.MemoryPoolExtra(
        ThreadLock,
        .{ .growable = false },
    ),
    /// Hash map of ThreadInfo structures, keyed by their Ids.
    /// Unlike Locks, these are stored directly in the hash map.
    threads: std.array_hash_map.Auto(std.Thread.Id, ThreadInfo),
    /// Pool of Waiting structures for fast allocation.
    waiting_pool: std.heap.MemoryPoolExtra(
        Waiting,
        .{ .growable = false },
    ),

    /// Maximum allowable amount of locks.
    pub const max_locks = 1024;

    /// Initialize the manager and allocate memory for it.
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

    /// Deinitialize the manager.
    pub fn deinit(self: *Manager, gpa: std.mem.Allocator) void {
        self.locks.deinit(gpa);
        self.lock_pool.deinit(gpa);
        self.thread_lock_pool.deinit(gpa);
        self.waiting_pool.deinit(gpa);
    }

    /// Can we grant a lock with this specific mode?
    fn canGrant(l: *const Lock, mode: Mode, me: std.Thread.Id) bool {
        // Set of modes the target mode can conflict with
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

    /// Rebuild the set of granted modes from scratch.
    /// Needed after any unlocking.
    fn rebuildGrantedSet(l: *Lock) void {
        l.granted_modes = .empty;
        var tl_node = l.granted_list.first;
        while (tl_node) |n| {
            const tl: *ThreadLock = @fieldParentPtr("per_lock_node", n);
            l.granted_modes.setUnion(tl.modes);
            tl_node = n.next;
        }
    }

    /// Grant the lock to a given thread.
    fn grant(self: *Manager, l: *Lock, id: Id, mode: Mode, me: std.Thread.Id) void {
        // Add to the set of granted modes
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

    /// Take a lock on some object.
    /// Requires a thread ID to distinguish between threads.
    pub fn lock(self: *Manager, id: Id, mode: Mode, me: std.Thread.Id) !void {
        // Hash maps are not thread-safe, so everything must be done under a mutex
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        // Get the Lock corresponding to the given Id.
        const r = self.locks.getOrPutAssumeCapacity(id);
        if (!r.found_existing) {
            // If didn't find one, allocate new one.
            const l = self.lock_pool.create(undefined) catch unreachable;
            l.* = .{};
            r.value_ptr.* = l;
        }
        // Remember the lock pointer, since the hash map entry might move later
        // due to concurrent access.
        const l = r.value_ptr.*;

        // Can we immediately grant this lock without waiting?
        if (canGrant(l, mode, me)) {
            std.debug.print("{}: Immediately got {} lock on {}\n", .{ me, mode, id });
            self.grant(l, id, mode, me);
            return;
        } else {
            // Nope, we can't, gotta wait
            {
                // Create a Waiting node and add it to the waiting queue.
                const waiting = self.waiting_pool.create(undefined) catch unreachable;
                waiting.* = .{
                    .thread = me,
                    .mode = mode,
                };
                l.waiting_list.prepend(&waiting.node);
            }

            {
                // Add a ThreadInfo if didn't have one
                const ti = self.threads.getOrPutAssumeCapacity(me);
                if (!ti.found_existing)
                    ti.value_ptr.* = .{};
                // Mark that we are waiting for this lock
                ti.value_ptr.waiting_lock = id;
            }

            std.debug.print("{}: Waiting for {} lock on {}\n", .{ me, mode, id });
            // Have to do this in a loop because of accidental wake ups
            while (true) {
                // Waiting temporarily unlocks the mutex, so all the
                // hash table entries might have moved after this.
                // We cannot rely on any previously acquired entries.
                // However, we *can* rely on the Lock structure itself
                // being at the same memory location, since it's in the pool.
                try l.condition.wait(self.io, &self.mutex);
                // We woke up, but only one waiting thread gets the lock.
                // We have to check if it's us.
                const ti = self.threads.get(me).?;
                // The unlock() method sets waiting_lock to null for all
                // threads that can be granted a lock.
                if (ti.waiting_lock == null)
                    break;
            }

            // We are done waiting, we can remove our Waiting node
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

    /// Unlock all locks currently held by this thread.
    pub fn unlockAll(self: *Manager, me: std.Thread.Id) !void {
        // Hash maps are not thread-safe, so everything must be done under a mutex
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        // If we don't have a ThreadInfo, we don't have any locks to unlock
        const ti = self.threads.getPtr(me);
        if (ti == null) return;
        // Shouldn't be unlocking anything if we are still waiting for a lock
        std.debug.assert(ti.?.waiting_lock == null);

        // Go through all ThreadLock nodes of this thread
        var tl_node = ti.?.granted_locks.first;
        while (tl_node) |n| {
            tl_node = n.next;
            const tl: *ThreadLock = @fieldParentPtr("per_thread_node", n);
            std.debug.print("{}: Starting to unlock {}\n", .{ me, tl.lock });

            // This is a lock we currently hold
            const l = self.locks.get(tl.lock).?;

            // Remove the node from both the lock and thread lists
            ti.?.granted_locks.remove(&tl.per_thread_node);
            l.granted_list.remove(&tl.per_lock_node);

            // We have to rebuild the granted modes set of the lock after this
            rebuildGrantedSet(l);

            // Is anyone waiting for this lock?
            if (l.waiting_list.last) |candidate_node| {
                const candidate: *Waiting = @fieldParentPtr("node", candidate_node);
                // Can we grant them this lock?
                if (canGrant(l, candidate.mode, candidate.thread)) {
                    // We can, mark them as finished waiting and wake everyone up.
                    std.debug.print("{}: Waking up {}\n", .{ me, candidate.thread });
                    self.threads.getPtr(candidate.thread).?.waiting_lock = null;
                    l.condition.broadcast(self.io);
                }
            }

            // Is there no one who needs this Lock anymore?
            if (l.granted_list.first == null and l.waiting_list.first == null) {
                // We can delete it
                std.debug.print("{}: Removed lock {}\n", .{ me, tl.lock });
                _ = self.locks.swapRemove(tl.lock);
                self.lock_pool.destroy(l);
            }

            std.debug.print("{}: Done unlocking {}\n", .{ me, tl.lock });

            // We can delete the ThreadLock node
            self.thread_lock_pool.destroy(tl);
        }

        // And we can delete the ThreadInfo too
        _ = self.threads.swapRemove(me);
        std.debug.print("{}: Done unlocking\n", .{me});
    }
};
