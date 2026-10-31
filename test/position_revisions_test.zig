const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const core = @import("labelle-core");
const Game = engine.game_mod.Game;

fn tracked(game: *Game, entity: Game.EntityType) !u64 {
    return (try game.trackPositionRevision(entity)).?;
}

test "position setters invalidate tracked descendants but not unrelated entities" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    const root = game.createEntity();
    const child = game.createEntity();
    const leaf = game.createEntity();
    const other = game.createEntity();
    game.setParent(child, root, .{});
    game.setParent(leaf, child, .{});
    var revision = try tracked(&game, leaf);
    const other_revision = try tracked(&game, other);
    try testing.expectEqual(null, game.positionRevision(root));
    game.setPosition(root, .{ .x = 1 });
    try testing.expect(game.positionRevision(leaf).? > revision);
    revision = game.positionRevision(leaf).?;
    game.setComponent(root, core.Position{ .x = 2 });
    try testing.expect(game.positionRevision(leaf).? > revision);
    revision = game.positionRevision(leaf).?;
    game.setField(core.Position, .x, root, 3);
    try testing.expect(game.positionRevision(leaf).? > revision);
    revision = game.positionRevision(leaf).?;
    game.removeComponent(root, core.Position);
    try testing.expect(game.positionRevision(leaf).? > revision);
    try testing.expectEqual(other_revision, game.positionRevision(other));
}

test "generic Parent writes maintain ancestry and invalidate before the next read" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    const a = game.createEntity();
    const b = game.createEntity();
    const child = game.createEntity();
    const leaf = game.createEntity();
    game.setParent(leaf, child, .{});
    var revision = try tracked(&game, leaf);
    game.addComponent(child, Game.ParentComp{ .entity = a });
    try testing.expect(game.positionRevision(leaf).? > revision);
    revision = game.positionRevision(leaf).?;
    game.setField(Game.ParentComp, .entity, child, b);
    try testing.expectEqual(@as(usize, 0), game.getChildren(a).len);
    try testing.expectEqual(child, game.getChildren(b)[0]);
    try testing.expect(game.positionRevision(leaf).? > revision);
    revision = game.positionRevision(leaf).?;
    game.setPosition(b, .{ .x = 1 });
    try testing.expect(game.positionRevision(leaf).? > revision);
    revision = game.positionRevision(leaf).?;
    game.removeComponent(child, Game.ParentComp);
    try testing.expect(game.positionRevision(leaf).? > revision);
    try testing.expectEqual(@as(usize, 0), game.getChildren(b).len);
}

test "destruction and ECS reset cannot reuse a previously observed token" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    const parent = game.createEntity();
    const child = game.createEntity();
    game.setParent(child, parent, .{});
    const before = try tracked(&game, child);
    _ = try tracked(&game, parent);
    game.destroyEntityOnly(parent);
    try testing.expectEqual(null, game.positionRevision(parent));
    try testing.expect(game.positionRevision(child).? > before);
    const old = game.positionRevision(child).?;
    game.resetEcsBackend();
    const replacement = game.createEntity();
    try testing.expectEqual(null, game.positionRevision(replacement));
    try testing.expect((try tracked(&game, replacement)) > old);
}

test "raw Children mutation fails closed for subsequent ancestor changes" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    const parent = game.createEntity();
    const child = game.createEntity();
    game.setParent(child, parent, .{});
    _ = try tracked(&game, child);
    game.removeComponent(parent, Game.ChildrenComp);
    const before = game.positionRevision(child).?;
    game.setPosition(parent, .{ .x = 1 });
    try testing.expect(game.positionRevision(child).? > before);
}

test "tracking failure leaves no fake ready revision; reads do not allocate" {
    var revisions = engine.PositionRevisions{};
    var bytes: [0]u8 = .{};
    var allocator = std.heap.FixedBufferAllocator.init(&bytes);
    defer revisions.deinit(allocator.allocator());
    try testing.expectError(error.OutOfMemory, revisions.track(allocator.allocator(), 1));
    try testing.expectEqual(null, revisions.get(1));
    revisions.invalidate(1);
    try testing.expectEqual(null, revisions.get(1));
}

test "revision storage follows world switches without leaking identities" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    try game.createWorld("a");
    try game.createWorld("b");
    try game.setActiveWorld("a");
    const a = game.createEntity();
    const before = try tracked(&game, a);
    try game.setActiveWorld("b");
    const b = game.createEntity();
    try testing.expectEqual(null, game.positionRevision(b));
    _ = try tracked(&game, b);
    game.setPosition(b, .{ .x = 9 });
    try game.setActiveWorld("a");
    try testing.expectEqual(before, game.positionRevision(a));
}

test "dependency group changes for watched ancestry and components, not ordinary movement" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    const Input = struct { value: u32 = 0 };
    const parent = game.createEntity();
    const node = game.createEntity();
    const worker = game.createEntity();
    game.setParent(node, parent, .{});
    try game.watchPositionDependency(node);
    try game.watchComponentDependency(Input);
    _ = try tracked(&game, worker);
    var revision = game.dependencyRevision();
    game.setPosition(worker, .{ .x = 1 });
    try testing.expectEqual(revision, game.dependencyRevision());
    game.setPosition(parent, .{ .x = 1 });
    try testing.expect(game.dependencyRevision() != revision);
    revision = game.dependencyRevision();
    game.addComponent(worker, Input{});
    try testing.expect(game.dependencyRevision() != revision);
    revision = game.dependencyRevision();
    game.setField(Input, .value, worker, 3);
    try testing.expect(game.dependencyRevision() != revision);
    revision = game.dependencyRevision();
    game.removeComponent(worker, Input);
    try testing.expect(game.dependencyRevision() != revision);
    revision = game.dependencyRevision();
    game.destroyEntity(node);
    try testing.expect(game.dependencyRevision() != revision);
}

test "indexed revision slots reject stale identities and stay bounded during churn" {
    var revisions = engine.PositionRevisions{};
    defer revisions.deinit(testing.allocator);
    const original = try revisions.track(testing.allocator, 1);
    const slot = revisions.slot(1).?;
    revisions.invalidate(1);
    try testing.expect(revisions.getAt(1, slot).? > original);
    revisions.forget(1);
    try testing.expectEqual(null, revisions.getAt(1, slot));
    for (2..1000) |entity| {
        _ = try revisions.track(testing.allocator, entity);
        try testing.expectEqual(slot, revisions.slot(entity).?);
        try testing.expectEqual(null, revisions.getAt(1, slot));
        revisions.forget(entity);
    }
    try testing.expectEqual(@as(usize, 1), revisions.slots.items.len);
    const replacement = try revisions.track(testing.allocator, 1);
    try testing.expect(replacement > original);
    revisions.reset();
    try testing.expectEqual(null, revisions.getAt(1, slot));
    try testing.expect((try revisions.track(testing.allocator, 1)) > replacement);
    try testing.expectEqual(null, revisions.getAt(1, std.math.maxInt(u32)));
}

fn checkSlotAllocation(allocator: std.mem.Allocator) !void {
    var revisions = engine.PositionRevisions{};
    defer revisions.deinit(allocator);
    _ = revisions.track(allocator, 1) catch |err| {
        try testing.expectEqual(null, revisions.get(1));
        try testing.expectEqual(null, revisions.slot(1));
        return err;
    };
    try testing.expectEqual(revisions.get(1), revisions.getAt(1, revisions.slot(1).?));
}

test "every registration allocation failure rolls back the indexed entry" {
    try testing.checkAllAllocationFailures(testing.allocator, checkSlotAllocation, .{});
}

test "pending notifications coalesce and stale acknowledgements cannot erase new movement" {
    var r = engine.PositionRevisions{};
    defer r.deinit(testing.allocator);
    try r.watchChanges(testing.allocator, 1);
    try r.watchChanges(testing.allocator, 2);
    const before = r.get(1).?;
    r.invalidate(1);
    r.invalidate(1);
    r.acknowledge(1, before);
    var it = r.pendingIterator();
    try testing.expectEqual(@as(?u64, 2), it.next());
    r.acknowledge(2, r.get(2).?);
    try testing.expectEqual(@as(?u64, 1), it.next());
    r.acknowledge(1, r.get(1).?);
    try testing.expectEqual(null, it.next());
    try testing.expectEqual(null, r.pending_head);
    r.invalidateAll();
    r.unwatchChanges(1);
    r.forget(2);
    try testing.expectEqual(null, r.pending_head);
    try r.watchChanges(testing.allocator, 3); // recycled slot has no stale links
    it = r.pendingIterator();
    try testing.expectEqual(@as(?u64, 3), it.next());
    try testing.expectEqual(null, it.next());
    r.reset();
    try testing.expectEqual(null, r.pending_head);
}

test "membership watches ignore value updates and notify additions removals and raw companion" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    const Domain = struct { value: u32 = 0 };
    const r = &game.active_world.position_revisions;
    try r.watchMembership(testing.allocator, Domain);
    const e = game.createEntity();
    var before = r.membership_revision;
    game.addComponent(e, Domain{});
    try testing.expect(r.membership_revision != before);
    before = r.membership_revision;
    game.addComponent(e, Domain{ .value = 1 });
    game.setComponent(e, Domain{ .value = 2 });
    game.setField(Domain, .value, e, 3);
    try testing.expectEqual(before, r.membership_revision);
    game.removeComponent(e, Domain);
    try testing.expect(r.membership_revision != before);
    before = r.membership_revision;
    game.removeComponent(e, Domain);
    try testing.expectEqual(before, r.membership_revision);
    game.active_world.ecs_backend.addComponent(e, Domain{});
    game.invalidateComponentMembership(Domain);
    try testing.expect(r.membership_revision != before);
}

test "snapshot executor joins delayed work and reuses its worker across batches" {
    var executor = engine.SnapshotExecutor{};
    defer executor.deinit();
    const Job = struct {
        values: [16]u32 = @splat(0),
        fn run(raw: *anyopaque, start: usize, end: usize) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            // Make the worker lane later than the main lane.
            if (start == 0) for (0..100) |_| {
                std.Thread.yield() catch {};
            };
            for (start..end) |i| self.values[i] += 1;
        }
    };
    var job = Job{};
    for (0..8) |_| _ = executor.run(&job, job.values.len, Job.run);
    for (job.values) |value| try testing.expectEqual(@as(u32, 8), value);
    try testing.expectEqual(@as(u32, 0), executor.state.load(.acquire));
}
