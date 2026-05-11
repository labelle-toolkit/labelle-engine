//! `Game.collectEntities` / `Game.collectEntitiesBuf` — public
//! view-collection helpers that absorb the "collect first, then
//! mutate" boilerplate every game-side dispatcher / hook / tick
//! was hand-rolling. Issue #510.

const std = @import("std");
const testing = std.testing;

const engine = @import("engine");
const game_mod = engine.game_mod;

const TestGame = game_mod.Game;

const Health = struct {
    current: f32 = 0,
    max: f32 = 100,
};

const Velocity = struct {
    x: f32 = 0,
    y: f32 = 0,
};

const Dying = struct {
    timer: f32 = 0,
};

// ── Heap variant ────────────────────────────────────────────────────

test "collectEntities: empty view returns an empty list" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    var list = try game.collectEntities(.{Health}, .{}, testing.allocator);
    defer list.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), list.items.len);
}

test "collectEntities: gathers every entity matching the include set" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const e1 = game.createEntity();
    const e2 = game.createEntity();
    const e3 = game.createEntity();
    game.ecs_backend.addComponent(e1, Health{ .current = 50 });
    game.ecs_backend.addComponent(e2, Health{ .current = 75 });
    // e3 has no Health — should be excluded.
    game.ecs_backend.addComponent(e3, Velocity{ .x = 1 });

    var list = try game.collectEntities(.{Health}, .{}, testing.allocator);
    defer list.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), list.items.len);
}

test "collectEntities: exclude tuple drops matching entities" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const e1 = game.createEntity();
    const e2 = game.createEntity();
    game.ecs_backend.addComponent(e1, Health{ .current = 100 });
    game.ecs_backend.addComponent(e2, Health{ .current = 0 });
    // e2 is also dying — should be excluded by the `Dying` filter.
    game.ecs_backend.addComponent(e2, Dying{});

    var list = try game.collectEntities(.{Health}, .{Dying}, testing.allocator);
    defer list.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), list.items.len);
}

test "collectEntities: caller can mutate the world while iterating the result" {
    // The whole reason this helper exists — collecting first means
    // we can `addComponent` / `destroyEntity` on every returned
    // entity without worrying about the view's iterator going
    // stale mid-mutation.
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const e1 = game.createEntity();
    const e2 = game.createEntity();
    game.ecs_backend.addComponent(e1, Health{ .current = 0 });
    game.ecs_backend.addComponent(e2, Health{ .current = 0 });

    var list = try game.collectEntities(.{Health}, .{}, testing.allocator);
    defer list.deinit(testing.allocator);

    for (list.items) |ent| {
        game.ecs_backend.addComponent(ent, Dying{});
    }

    try testing.expect(game.ecs_backend.hasComponent(e1, Dying));
    try testing.expect(game.ecs_backend.hasComponent(e2, Dying));
}

// ── Stack-buffered variant ──────────────────────────────────────────

test "collectEntitiesBuf: empty view returns 0, overflowed stays false" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    var buf: [4]@TypeOf(game).EntityType = undefined;
    var overflowed = true; // intentional non-default — verify reset.
    const n = game.collectEntitiesBuf(.{Health}, .{}, &buf, &overflowed);
    try testing.expectEqual(@as(usize, 0), n);
    try testing.expect(!overflowed);
}

test "collectEntitiesBuf: fills the buffer up to its capacity" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const ent = game.createEntity();
        game.ecs_backend.addComponent(ent, Health{});
    }

    var buf: [4]@TypeOf(game).EntityType = undefined;
    var overflowed = false;
    const n = game.collectEntitiesBuf(.{Health}, .{}, &buf, &overflowed);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expect(!overflowed);
}

test "collectEntitiesBuf: sets overflowed when the view exceeds the buffer" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    // Spawn more entities than the buffer can hold so the overflow
    // flag has to fire.
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        const ent = game.createEntity();
        game.ecs_backend.addComponent(ent, Health{});
    }

    var buf: [4]@TypeOf(game).EntityType = undefined;
    var overflowed = false;
    const n = game.collectEntitiesBuf(.{Health}, .{}, &buf, &overflowed);
    // Buffer caps the count — overflowed signals "there were more".
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expect(overflowed);
}

test "collectEntitiesBuf: exclude tuple drops matching entities" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const alive = game.createEntity();
    const dying = game.createEntity();
    game.ecs_backend.addComponent(alive, Health{});
    game.ecs_backend.addComponent(dying, Health{});
    game.ecs_backend.addComponent(dying, Dying{});

    var buf: [4]@TypeOf(game).EntityType = undefined;
    var overflowed = false;
    const n = game.collectEntitiesBuf(.{Health}, .{Dying}, &buf, &overflowed);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(alive, buf[0]);
}
