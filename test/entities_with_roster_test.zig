//! `Game.entitiesWith(includes)` — the Packs roster primitive (#653).
//!
//! A dirty-tracked, cached collection: `entitiesWith` hands back a
//! slice **borrowed from an engine-owned cache**, valid only until the
//! next structural mutation. A monotonic generation counter is bumped
//! on component add/remove and entity create/destroy; reads lazily
//! re-query only when the cached slot is stale for that tag-set.
//!
//! These tests cover: the roster returns the right entities, the cache
//! invalidates on add/remove, and the returned slice reflects the
//! latest set after a refresh.

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

fn contains(slice: []const TestGame.EntityType, e: TestGame.EntityType) bool {
    for (slice) |x| if (x == e) return true;
    return false;
}

test "entitiesWith: empty world yields an empty roster" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const roster = game.entitiesWith(.{Health});
    try testing.expectEqual(@as(usize, 0), roster.len);
}

test "entitiesWith: returns exactly the entities holding the tag" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const e1 = game.createEntity();
    const e2 = game.createEntity();
    const e3 = game.createEntity();
    game.addComponent(e1, Health{ .current = 50 });
    game.addComponent(e2, Health{ .current = 75 });
    // e3 has only Velocity — must be excluded.
    game.addComponent(e3, Velocity{ .x = 1 });

    const roster = game.entitiesWith(.{Health});
    try testing.expectEqual(@as(usize, 2), roster.len);
    try testing.expect(contains(roster, e1));
    try testing.expect(contains(roster, e2));
    try testing.expect(!contains(roster, e3));
}

test "entitiesWith: multi-component tag-set intersects the includes" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const e1 = game.createEntity();
    const e2 = game.createEntity();
    game.addComponent(e1, Health{});
    game.addComponent(e1, Velocity{});
    game.addComponent(e2, Health{}); // no Velocity

    const roster = game.entitiesWith(.{ Health, Velocity });
    try testing.expectEqual(@as(usize, 1), roster.len);
    try testing.expect(contains(roster, e1));
}

test "entitiesWith: repeated reads in a mutation-free window return the same cached slice" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const e1 = game.createEntity();
    game.addComponent(e1, Health{});

    const first = game.entitiesWith(.{Health});
    const second = game.entitiesWith(.{Health});
    // Borrowed from the same engine-owned slot — identical pointer and length.
    try testing.expectEqual(first.ptr, second.ptr);
    try testing.expectEqual(first.len, second.len);
}

test "entitiesWith: cache invalidates when a component is added" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const e1 = game.createEntity();
    game.addComponent(e1, Health{});

    try testing.expectEqual(@as(usize, 1), game.entitiesWith(.{Health}).len);

    // Structural mutation: a new Health-bearing entity must show up on
    // the next read without the caller doing anything special.
    const e2 = game.createEntity();
    game.addComponent(e2, Health{});

    const refreshed = game.entitiesWith(.{Health});
    try testing.expectEqual(@as(usize, 2), refreshed.len);
    try testing.expect(contains(refreshed, e1));
    try testing.expect(contains(refreshed, e2));
}

test "entitiesWith: cache invalidates when a component is removed" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const e1 = game.createEntity();
    const e2 = game.createEntity();
    game.addComponent(e1, Health{});
    game.addComponent(e2, Health{});

    try testing.expectEqual(@as(usize, 2), game.entitiesWith(.{Health}).len);

    game.removeComponent(e1, Health);

    const refreshed = game.entitiesWith(.{Health});
    try testing.expectEqual(@as(usize, 1), refreshed.len);
    try testing.expect(!contains(refreshed, e1));
    try testing.expect(contains(refreshed, e2));
}

test "entitiesWith: roster reflects the latest set after a destroy + refresh" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const e1 = game.createEntity();
    const e2 = game.createEntity();
    game.addComponent(e1, Health{});
    game.addComponent(e2, Health{});
    try testing.expectEqual(@as(usize, 2), game.entitiesWith(.{Health}).len);

    game.destroyEntity(e2);

    const refreshed = game.entitiesWith(.{Health});
    try testing.expectEqual(@as(usize, 1), refreshed.len);
    try testing.expect(contains(refreshed, e1));
    try testing.expect(!contains(refreshed, e2));
}

test "entitiesWith: distinct tag-sets cache independently" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const e1 = game.createEntity();
    const e2 = game.createEntity();
    game.addComponent(e1, Health{});
    game.addComponent(e2, Velocity{});

    const health_roster = game.entitiesWith(.{Health});
    const velocity_roster = game.entitiesWith(.{Velocity});

    try testing.expectEqual(@as(usize, 1), health_roster.len);
    try testing.expectEqual(@as(usize, 1), velocity_roster.len);
    try testing.expect(contains(health_roster, e1));
    try testing.expect(contains(velocity_roster, e2));
    // Separate slots → separate backing storage.
    try testing.expect(health_roster.ptr != velocity_roster.ptr);
}

test "entitiesWith: tag-set order does not matter — same slot for .{A,B} and .{B,A}" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const e1 = game.createEntity();
    game.addComponent(e1, Health{});
    game.addComponent(e1, Velocity{});

    // The cache key sorts component type names before hashing, so both
    // orderings resolve to the SAME slot and share backing storage —
    // no duplicate slot, no thrash between two orderings of one query.
    const ab = game.entitiesWith(.{ Health, Velocity });
    const ba = game.entitiesWith(.{ Velocity, Health });

    try testing.expectEqual(@as(usize, 1), ab.len);
    try testing.expectEqual(@as(usize, 1), ba.len);
    // Same engine-owned slot → identical backing pointer.
    try testing.expectEqual(ab.ptr, ba.ptr);
    try testing.expect(contains(ba, e1));
}
