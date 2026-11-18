const std = @import("std");

/// Opt-in, world-owned freshness tokens. Reads never allocate or repair.
/// Tokens are never reused after untracking/reset; overflow fails closed.
pub const PositionRevisions = struct {
    entries: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    serial: u64 = 0,
    hierarchy_untrusted: bool = false,

    pub fn deinit(self: *PositionRevisions, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
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

    pub fn invalidate(self: *PositionRevisions, entity: u64) void {
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
        var values = self.entries.valueIterator();
        while (values.next()) |value| value.* = revision;
    }

    pub fn forget(self: *PositionRevisions, entity: u64) void {
        _ = self.entries.remove(entity);
    }

    pub fn reset(self: *PositionRevisions) void {
        self.entries.clearRetainingCapacity();
        self.hierarchy_untrusted = false;
    }
};
