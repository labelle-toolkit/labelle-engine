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
