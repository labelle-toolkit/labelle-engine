const std = @import("std");

/// Opt-in, world-owned freshness tokens. Reads never allocate or repair.
/// Tokens are never reused after untracking/reset; overflow fails closed.
pub const PositionRevisions = struct {
    const Slot = struct { entity: u64, revision: u64, next_free: ?u32 = null, watched: bool = false, pending: bool = false, prev: ?u32 = null, next_pending: ?u32 = null };
    entries: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    slots: std.ArrayListUnmanaged(Slot) = .empty,
    free_slot: ?u32 = null,
    pending_head: ?u32 = null,
    membership_types: std.AutoHashMapUnmanaged(u64, void) = .empty,
    membership_revision: u64 = 0,
    serial: u64 = 0,
    watched_entities: std.AutoHashMapUnmanaged(u64, void) = .empty,
    watched_components: std.AutoHashMapUnmanaged(u64, void) = .empty,
    dependency_revision: u64 = 0,
    hierarchy_untrusted: bool = false,

    pub fn deinit(self: *PositionRevisions, allocator: std.mem.Allocator) void {
        self.membership_types.deinit(allocator);
        self.entries.deinit(allocator);
        self.slots.deinit(allocator);
        self.watched_entities.deinit(allocator);
        self.watched_components.deinit(allocator);
    }

    fn next(self: *PositionRevisions) u64 {
        if (self.serial == std.math.maxInt(u64)) @panic("position revision exhausted");
        self.serial += 1;
        return self.serial;
    }

    pub fn track(self: *PositionRevisions, allocator: std.mem.Allocator, entity: u64) !u64 {
        const entry = try self.entries.getOrPut(allocator, entity);
        if (!entry.found_existing) {
            errdefer _ = self.entries.remove(entity);
            const index = if (self.free_slot) |index| blk: {
                self.free_slot = self.slots.items[index].next_free;
                break :blk index;
            } else blk: {
                if (self.slots.items.len >= std.math.maxInt(u32)) return error.OutOfMemory;
                try self.slots.append(allocator, undefined);
                break :blk @as(u32, @intCast(self.slots.items.len - 1));
            };
            entry.value_ptr.* = index;
            self.slots.items[index] = .{ .entity = entity, .revision = self.next() };
        }
        return self.slots.items[entry.value_ptr.*].revision;
    }

    /// One opt-in consumer per world. Queue links live in already allocated
    /// revision slots: movement cannot lose notifications through allocation failure.
    pub fn watchChanges(self: *PositionRevisions, allocator: std.mem.Allocator, entity: u64) !void {
        _ = try self.track(allocator, entity);
        const index = self.slot(entity).?;
        if (!self.slots.items[index].watched) {
            self.slots.items[index].watched = true;
            self.enqueue(index);
        }
    }

    fn enqueue(self: *PositionRevisions, index: u32) void {
        const value = &self.slots.items[index];
        if (!value.watched or value.pending) return;
        value.pending = true;
        value.prev = null;
        value.next_pending = self.pending_head;
        if (self.pending_head) |head| self.slots.items[head].prev = index;
        self.pending_head = index;
    }

    fn unlink(self: *PositionRevisions, index: u32) void {
        const value = &self.slots.items[index];
        if (!value.pending) return;
        if (value.prev) |prev| self.slots.items[prev].next_pending = value.next_pending else self.pending_head = value.next_pending;
        if (value.next_pending) |next_index| self.slots.items[next_index].prev = value.prev;
        value.pending = false;
        value.prev = null;
        value.next_pending = null;
    }

    pub fn markPending(self: *PositionRevisions, entity: u64) void {
        if (self.slot(entity)) |index| self.enqueue(index);
    }

    pub fn markAllPending(self: *PositionRevisions) void {
        for (self.slots.items, 0..) |value, i| {
            if (value.revision != 0) self.enqueue(@intCast(i));
        }
    }

    pub fn acknowledge(self: *PositionRevisions, entity: u64, revision: u64) void {
        const index = self.slot(entity) orelse return;
        if (self.slots.items[index].revision == revision) self.unlink(index);
    }

    pub fn unwatchChanges(self: *PositionRevisions, entity: u64) void {
        const index = self.slot(entity) orelse return;
        self.unlink(index);
        self.slots.items[index].watched = false;
    }

    pub const PendingIterator = struct {
        owner: *PositionRevisions,
        next_index: ?u32,
        pub fn next(self: *PendingIterator) ?u64 {
            const index = self.next_index orelse return null;
            const value = self.owner.slots.items[index];
            self.next_index = value.next_pending;
            return value.entity;
        }
    };

    /// The current element may be acknowledged/unwatched during iteration.
    /// Do not register, destroy other entities, or mutate positions until done.
    pub fn pendingIterator(self: *PositionRevisions) PendingIterator {
        return .{ .owner = self, .next_index = self.pending_head };
    }

    pub fn watchMembership(self: *PositionRevisions, allocator: std.mem.Allocator, comptime T: type) !void {
        const entry = try self.membership_types.getOrPut(allocator, comptime std.hash.Wyhash.hash(0, @typeName(T)));
        if (!entry.found_existing) self.membership_revision = self.next();
    }

    pub fn watchesMembership(self: *const PositionRevisions, comptime T: type) bool {
        return self.membership_types.contains(comptime std.hash.Wyhash.hash(0, @typeName(T)));
    }

    pub fn invalidateMembership(self: *PositionRevisions, comptime T: type) void {
        if (self.watchesMembership(T)) self.membership_revision = self.next();
    }

    /// Registration-time handle. No pointers escape growable storage.
    pub fn slot(self: *const PositionRevisions, entity: u64) ?u32 {
        return self.entries.get(entity);
    }

    /// Constant-time freshness read. Reused slots/identities receive a fresh
    /// revision; consumers must compare the returned revision with their stamp.
    pub fn getAt(self: *const PositionRevisions, entity: u64, index: u32) ?u64 {
        if (index >= self.slots.items.len) return null;
        const value = self.slots.items[index];
        if (value.revision == 0 or value.entity != entity) return null;
        return value.revision;
    }

    pub fn get(self: *const PositionRevisions, entity: u64) ?u64 {
        return self.getAt(entity, self.slot(entity) orelse return null);
    }

    /// One conservative dependency group per world. Registration is preparation
    /// work; reading dependency_revision is allocation-free and constant-time.
    pub fn watchPosition(self: *PositionRevisions, allocator: std.mem.Allocator, entity: u64) !void {
        _ = try self.track(allocator, entity);
        const entry = try self.watched_entities.getOrPut(allocator, entity);
        if (!entry.found_existing) self.dependency_revision = self.next();
    }

    pub fn watchComponent(self: *PositionRevisions, allocator: std.mem.Allocator, comptime T: type) !void {
        const entry = try self.watched_components.getOrPut(allocator, comptime std.hash.Wyhash.hash(0, @typeName(T)));
        if (!entry.found_existing) self.dependency_revision = self.next();
    }

    pub fn invalidateComponent(self: *PositionRevisions, comptime T: type) void {
        if (self.watched_components.contains(comptime std.hash.Wyhash.hash(0, @typeName(T)))) self.dependency_revision = self.next();
    }

    pub fn invalidate(self: *PositionRevisions, entity: u64) void {
        if (self.watched_entities.contains(entity)) self.dependency_revision = self.next();
        if (self.entries.get(entity)) |index| {
            self.slots.items[index].revision = self.next();
            self.enqueue(index);
        }
    }

    /// Raw Children replacement may break the reverse index. Fail closed on
    /// subsequent mutations until world reset rather than trust that index.
    pub fn invalidateHierarchy(self: *PositionRevisions) void {
        self.hierarchy_untrusted = true;
        self.invalidateAll();
    }

    pub fn invalidateAll(self: *PositionRevisions) void {
        if (self.entries.count() == 0) return;
        const revision = self.next();
        if (self.watched_entities.count() != 0) self.dependency_revision = revision;
        for (self.slots.items, 0..) |*value, i| {
            if (value.revision != 0) {
                value.revision = revision;
                self.enqueue(@intCast(i));
            }
        }
    }

    pub fn forget(self: *PositionRevisions, entity: u64) void {
        if (self.watched_entities.remove(entity)) self.dependency_revision = self.next();
        if (self.entries.fetchRemove(entity)) |entry| {
            self.unlink(entry.value);
            self.slots.items[entry.value] = .{ .entity = entity, .revision = 0, .next_free = self.free_slot };
            self.free_slot = entry.value;
        }
    }

    pub fn reset(self: *PositionRevisions) void {
        self.entries.clearRetainingCapacity();
        self.slots.clearRetainingCapacity();
        self.free_slot = null;
        self.pending_head = null;
        self.membership_types.clearRetainingCapacity();
        self.membership_revision = self.next();
        self.watched_entities.clearRetainingCapacity();
        self.watched_components.clearRetainingCapacity();
        self.dependency_revision = self.next();
        self.hierarchy_untrusted = false;
    }
};
