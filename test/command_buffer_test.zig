//! CommandBuffer(Command) facility tests (labelle-engine#615).
//!
//! Exercises the three responsibilities the engine graduated from
//! flying-platform's vendored plugin: enqueue (growable, engine-owned
//! storage), conflict detection (write-key overlap + the release-before-
//! acquire handoff exemption), and deferred apply (single controlled
//! pass at a safe sync point, then clear).

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");

/// A minimal, game-agnostic `Command` type satisfying the buffer's
/// comptime contract. Stands in for a game's domain union.
const Command = union(enum) {
    /// Acquire `worker` into a job at `station` (two write-keys).
    assign: struct { worker: u64, station: u64 },
    /// Acquire `worker` into a wander (one write-key).
    wander: struct { worker: u64 },
    /// Release `worker` back to idle.
    complete: struct { worker: u64 },

    pub fn writeKeys(self: Command) [2]?u64 {
        return switch (self) {
            .assign => |c| .{ c.worker, c.station },
            .wander => |c| .{ c.worker, null },
            .complete => |c| .{ c.worker, null },
        };
    }

    pub fn releasesWorker(self: Command) bool {
        return self == .complete;
    }

    pub fn acquiresWorker(self: Command) bool {
        return switch (self) {
            .assign, .wander => true,
            .complete => false,
        };
    }

    pub fn workerKey(self: Command) ?u64 {
        return switch (self) {
            .assign => |c| c.worker,
            .wander => |c| c.worker,
            .complete => |c| c.worker,
        };
    }
};

/// A `Command` whose release variant writes an EXTRA key beyond its
/// worker — used to prove the handoff exemption is scoped to the worker
/// key, not the whole pair.
const LockCommand = union(enum) {
    /// Releases `worker` but also releases a lock on `resource`.
    complete_and_unlock: struct { worker: u64, resource: u64 },
    /// Acquires `worker` onto `resource` (a genuine race on `resource`).
    assign_locked: struct { worker: u64, resource: u64 },

    pub fn writeKeys(self: LockCommand) [2]?u64 {
        return switch (self) {
            .complete_and_unlock => |c| .{ c.worker, c.resource },
            .assign_locked => |c| .{ c.worker, c.resource },
        };
    }

    pub fn releasesWorker(self: LockCommand) bool {
        return self == .complete_and_unlock;
    }

    pub fn acquiresWorker(self: LockCommand) bool {
        return self == .assign_locked;
    }

    pub fn workerKey(self: LockCommand) ?u64 {
        return switch (self) {
            .complete_and_unlock => |c| c.worker,
            .assign_locked => |c| c.worker,
        };
    }
};

const Buffer = engine.CommandBuffer(Command);
const LockBuffer = engine.CommandBuffer(LockCommand);

test "inferred key type and arity" {
    try testing.expectEqual(u64, Buffer.KeyType);
    try testing.expectEqual(@as(usize, 2), Buffer.key_slots);
    try testing.expectEqual(u64, engine.CommandKey(Command));
    try testing.expectEqual(@as(usize, 2), engine.commandKeyCount(Command));
}

test "enqueue: growable, engine-owned storage" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();

    try testing.expectEqual(@as(usize, 0), buf.count());

    // Push well past any fixed capacity to prove storage grows.
    var i: u64 = 0;
    while (i < 500) : (i += 1) {
        try buf.push(.{ .wander = .{ .worker = i } });
    }
    try testing.expectEqual(@as(usize, 500), buf.count());
    try testing.expectEqual(@as(usize, 500), buf.slice().len);

    buf.clear();
    try testing.expectEqual(@as(usize, 0), buf.count());
}

test "conflict detection: two acquires on the same worker" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();

    try buf.push(.{ .assign = .{ .worker = 7, .station = 100 } });
    try buf.push(.{ .wander = .{ .worker = 7 } }); // same worker → race
    try buf.push(.{ .assign = .{ .worker = 8, .station = 101 } }); // unrelated

    const report = buf.detectConflicts();
    try testing.expectEqual(@as(usize, 1), report.len);
    try testing.expect(!report.overflow);
    const c = report.slice()[0];
    try testing.expectEqual(@as(usize, 0), c.cmd_a);
    try testing.expectEqual(@as(usize, 1), c.cmd_b);
    try testing.expectEqual(@as(u64, 7), c.entity);
}

test "conflict detection: shared station key across two assigns" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();

    // Different workers, but two items into the same station slot.
    try buf.push(.{ .assign = .{ .worker = 1, .station = 42 } });
    try buf.push(.{ .assign = .{ .worker = 2, .station = 42 } });

    const report = buf.detectConflicts();
    try testing.expectEqual(@as(usize, 1), report.len);
    try testing.expectEqual(@as(u64, 42), report.slice()[0].entity);
}

test "conflict detection: release-before-acquire handoff is exempt" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();

    // Legal handoff: worker 5 completes, then is re-assigned same frame.
    try buf.push(.{ .complete = .{ .worker = 5 } });
    try buf.push(.{ .assign = .{ .worker = 5, .station = 9 } });

    const report = buf.detectConflicts();
    try testing.expect(report.isEmpty());
    try testing.expectEqual(@as(usize, 0), report.len);
}

test "conflict detection: acquire-before-release stays flagged" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();

    // Suspect ordering — NOT exempt (the exemption is one-directional).
    try buf.push(.{ .assign = .{ .worker = 5, .station = 9 } });
    try buf.push(.{ .complete = .{ .worker = 5 } });

    const report = buf.detectConflicts();
    try testing.expectEqual(@as(usize, 1), report.len);
    try testing.expectEqual(@as(u64, 5), report.slice()[0].entity);
}

test "handoff exemption is scoped to the worker key, not other shared keys" {
    var buf = LockBuffer.init(testing.allocator);
    defer buf.deinit();

    // Legal handoff on worker 5, but BOTH commands also touch resource
    // 99 — that's a genuine race the pair-level exemption used to hide.
    try buf.push(.{ .complete_and_unlock = .{ .worker = 5, .resource = 99 } });
    try buf.push(.{ .assign_locked = .{ .worker = 5, .resource = 99 } });

    const report = buf.detectConflicts();
    // Worker 5 exempt (handoff); resource 99 still flagged.
    try testing.expectEqual(@as(usize, 1), report.len);
    try testing.expectEqual(@as(u64, 99), report.slice()[0].entity);
}

test "handoff on worker with disjoint resource keys is fully exempt" {
    var buf = LockBuffer.init(testing.allocator);
    defer buf.deinit();

    // Same worker handoff, but different resources → nothing else shared.
    try buf.push(.{ .complete_and_unlock = .{ .worker = 5, .resource = 1 } });
    try buf.push(.{ .assign_locked = .{ .worker = 5, .resource = 2 } });

    const report = buf.detectConflicts();
    try testing.expect(report.isEmpty());
}

test "conflict detection: report caps at MAX_CONFLICTS with overflow flagged" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();

    // 10 acquires on the same worker → 45 conflicting pairs, well past
    // MAX_CONFLICTS (32). The report caps and flags overflow (and bails
    // early once full rather than finishing the O(N^2) sweep).
    var i: u64 = 0;
    while (i < 10) : (i += 1) {
        try buf.push(.{ .wander = .{ .worker = 1 } });
    }

    const report = buf.detectConflicts();
    try testing.expectEqual(Buffer.ConflictReport.MAX_CONFLICTS, report.len);
    try testing.expect(report.overflow);
    try testing.expect(!report.isEmpty());
}

/// Apply context: records applied worker ids in push order.
const World = struct {
    applied: std.ArrayListUnmanaged(u64) = .empty,
    allocator: std.mem.Allocator,

    fn applyOne(self: *World, cmd: Command) void {
        const worker = switch (cmd) {
            .assign => |c| c.worker,
            .wander => |c| c.worker,
            .complete => |c| c.worker,
        };
        self.applied.append(self.allocator, worker) catch @panic("oom");
    }
};

test "deferred apply: single ordered pass, then clears" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();

    var world = World{ .allocator = testing.allocator };
    defer world.applied.deinit(testing.allocator);

    try buf.push(.{ .assign = .{ .worker = 10, .station = 1 } });
    try buf.push(.{ .complete = .{ .worker = 11 } });
    try buf.push(.{ .wander = .{ .worker = 12 } });

    buf.apply(&world, World.applyOne);

    // Applied in push order.
    try testing.expectEqualSlices(u64, &.{ 10, 11, 12 }, world.applied.items);
    // Buffer drained after apply.
    try testing.expectEqual(@as(usize, 0), buf.count());
}

/// Apply context that re-entrantly stages a follow-up command onto the
/// same buffer while applying — exercises the snapshot/retain path.
const Reentrant = struct {
    buf: *Buffer,
    applied: std.ArrayListUnmanaged(u64) = .empty,
    allocator: std.mem.Allocator,
    injected: bool = false,

    fn applyOne(self: *Reentrant, cmd: Command) void {
        const worker = switch (cmd) {
            .assign => |c| c.worker,
            .wander => |c| c.worker,
            .complete => |c| c.worker,
        };
        self.applied.append(self.allocator, worker) catch @panic("oom");
        // While applying the first command, enqueue a follow-up. It must
        // NOT be applied this pass, and must NOT be dropped by the clear.
        if (!self.injected and worker == 10) {
            self.injected = true;
            self.buf.push(.{ .wander = .{ .worker = 99 } }) catch @panic("oom");
        }
    }
};

test "deferred apply: re-entrant push survives, applied next pass" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();

    var ctx = Reentrant{ .buf = &buf, .allocator = testing.allocator };
    defer ctx.applied.deinit(testing.allocator);

    try buf.push(.{ .assign = .{ .worker = 10, .station = 1 } });
    try buf.push(.{ .wander = .{ .worker = 12 } });

    buf.apply(&ctx, Reentrant.applyOne);

    // Only the two snapshot commands were applied this pass.
    try testing.expectEqualSlices(u64, &.{ 10, 12 }, ctx.applied.items);
    // The re-entrant push survived for the next frame (not dropped).
    try testing.expectEqual(@as(usize, 1), buf.count());
    try testing.expectEqual(@as(u64, 99), buf.slice()[0].wander.worker);

    // Next pass drains the survivor.
    buf.apply(&ctx, Reentrant.applyOne);
    try testing.expectEqualSlices(u64, &.{ 10, 12, 99 }, ctx.applied.items);
    try testing.expectEqual(@as(usize, 0), buf.count());
}

test "detectConflictsSlice works over an arbitrary slice" {
    const cmds = [_]Command{
        .{ .assign = .{ .worker = 1, .station = 2 } },
        .{ .wander = .{ .worker = 1 } },
    };
    const report = Buffer.detectConflictsSlice(&cmds);
    try testing.expectEqual(@as(usize, 1), report.len);
    try testing.expectEqual(@as(u64, 1), report.slice()[0].entity);
}
