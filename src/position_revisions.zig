const std = @import("std");

/// Opt-in, world-owned freshness tokens. Reads never allocate or repair.
/// Tokens are never reused after untracking/reset; overflow fails closed.
pub const PositionRevisions = struct {
    entries: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    serial: u64 = 0,
    watched_entities: std.AutoHashMapUnmanaged(u64, void) = .empty,
    watched_components: std.AutoHashMapUnmanaged(u64, void) = .empty,
    dependency_revision: u64 = 0,
    hierarchy_untrusted: bool = false,

    pub fn deinit(self: *PositionRevisions, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
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
        if (!entry.found_existing) entry.value_ptr.* = self.next();
        return entry.value_ptr.*;
    }

    pub fn get(self: *const PositionRevisions, entity: u64) ?u64 {
        return self.entries.get(entity);
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
        if (self.entries.getPtr(entity)) |revision| revision.* = self.next();
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
        var values = self.entries.valueIterator();
        while (values.next()) |value| value.* = revision;
    }

    pub fn forget(self: *PositionRevisions, entity: u64) void {
        if (self.watched_entities.remove(entity)) self.dependency_revision = self.next();
        _ = self.entries.remove(entity);
    }

    pub fn reset(self: *PositionRevisions) void {
        self.entries.clearRetainingCapacity();
        self.watched_entities.clearRetainingCapacity();
        self.watched_components.clearRetainingCapacity();
        self.dependency_revision = self.next();
        self.hierarchy_untrusted = false;
    }
};
