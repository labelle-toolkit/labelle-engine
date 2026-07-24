/// #701 — `destroyEntity` / `destroyEntityOnly` must unlink the destroyed
/// entity from its parent's `Children` list.
///
/// Before the fix, a destroy-while-parented left a permanently stale id in
/// the parent's list: recycled indices later aliased it onto unrelated
/// entities (debug panics / silent cross-entity corruption on the zig-ecs
/// backend), a parent destroy recursed into the dead id, and every leaked
/// id permanently consumed one of the 16 `Children` slots. Observed in the
/// wild as Flying-Platform/flying-platform-labelle#603.
///
/// The regression trap covered here: the cascade in `destroyEntity` used
/// to iterate the live `getChildren()` slice — now that each child's
/// destroy swap-removes itself from that same list, the cascade iterates a
/// by-value snapshot instead. These tests assert the cascade stays
/// coherent (no skipped children, no double destroys, no bystander
/// corruption).
const std = @import("std");
const testing = std.testing;

const engine = @import("engine");
const Game = engine.Game;
const Entity = Game.EntityType;

fn childrenContain(game: *Game, parent: Entity, child: Entity) bool {
    for (game.getChildren(parent)) |c| {
        if (c == child) return true;
    }
    return false;
}

test "#701: destroying a child unlinks it from the parent's Children" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const parent = game.createEntity();
    const child = game.createEntity();
    game.setParent(child, parent, .{});
    try testing.expect(childrenContain(&game, parent, child));

    game.destroyEntity(child);

    // The id is gone from the parent's list…
    try testing.expect(!childrenContain(&game, parent, child));
    try testing.expectEqual(@as(usize, 0), game.getChildren(parent).len);
    // …and the parent survives, untouched.
    try testing.expect(game.ecs_backend.entityExists(parent));
    try testing.expect(!game.ecs_backend.entityExists(child));

    // The parent stays fully destroyable: before the fix its cascade
    // recursed into the stale child id and the backend destroy trapped
    // (#701 consequence 4).
    game.destroyEntity(parent);
    try testing.expectEqual(@as(usize, 0), game.entityCount());
}

test "#797: direct removeComponent / set / add of Children don't leak the list" {
    // The generic component API is a public path that bypasses the hierarchy
    // choke points: removing or overwriting a `Children` by value would drop
    // its heap list without freeing it. `game.deinit` runs under
    // `testing.allocator`, so any leaked child-list allocation fails here.
    var game = Game.init(testing.allocator);
    defer game.deinit();
    const Children = Game.ChildrenComp;

    const parent = game.createEntity();
    var i: usize = 0;
    while (i < 20) : (i += 1) game.setParent(game.createEntity(), parent, .{});
    try testing.expectEqual(@as(usize, 20), game.getChildren(parent).len);

    // Direct generic removal must free the backing list.
    game.removeComponent(parent, Children);
    try testing.expect(!game.hasComponent(parent, Children));

    // setComponent overwrite must free the replaced list.
    i = 0;
    while (i < 20) : (i += 1) game.setParent(game.createEntity(), parent, .{});
    game.setComponent(parent, Children{});
    try testing.expectEqual(@as(usize, 0), game.getChildren(parent).len);

    // addComponent overwrite must free the replaced list.
    i = 0;
    while (i < 20) : (i += 1) game.setParent(game.createEntity(), parent, .{});
    game.addComponent(parent, Children{});
    try testing.expectEqual(@as(usize, 0), game.getChildren(parent).len);
}

test "#701: destroying the middle child leaves the siblings listed" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const parent = game.createEntity();
    var kids: [5]Entity = undefined;
    for (&kids) |*k| {
        k.* = game.createEntity();
        game.setParent(k.*, parent, .{});
    }

    game.destroyEntity(kids[2]);

    // Membership (not order) is the list's contract — removeChild is a
    // swap-remove.
    try testing.expectEqual(@as(usize, 4), game.getChildren(parent).len);
    for (kids, 0..) |k, i| {
        if (i == 2) {
            try testing.expect(!childrenContain(&game, parent, k));
            try testing.expect(!game.ecs_backend.entityExists(k));
        } else {
            try testing.expect(childrenContain(&game, parent, k));
            try testing.expect(game.ecs_backend.entityExists(k));
        }
    }
}

test "#701: cascade destroy with several children survives the per-child unlink" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const parent = game.createEntity();
    var kids: [5]Entity = undefined;
    for (&kids) |*k| {
        k.* = game.createEntity();
        game.setParent(k.*, parent, .{});
    }
    // A bystander tree the cascade must not touch.
    const bystander = game.createEntity();
    const bystander_child = game.createEntity();
    game.setParent(bystander_child, bystander, .{});

    // Each child's destroy swap-removes it from the dying parent's live
    // list; the cascade must iterate a snapshot or it skips children /
    // double-destroys swap remnants.
    game.destroyEntity(parent);

    try testing.expect(!game.ecs_backend.entityExists(parent));
    for (kids) |k| {
        try testing.expect(!game.ecs_backend.entityExists(k));
    }
    // Bystanders intact.
    try testing.expect(game.ecs_backend.entityExists(bystander));
    try testing.expect(game.ecs_backend.entityExists(bystander_child));
    try testing.expect(childrenContain(&game, bystander, bystander_child));
    try testing.expectEqual(@as(usize, 2), game.entityCount());
}

test "#701: destroying the middle of a grandparent chain cascades down and updates the grandparent" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const grandparent = game.createEntity();
    const middle = game.createEntity();
    const leaf = game.createEntity();
    game.setParent(middle, grandparent, .{});
    game.setParent(leaf, middle, .{});

    game.destroyEntity(middle);

    try testing.expect(!game.ecs_backend.entityExists(middle));
    try testing.expect(!game.ecs_backend.entityExists(leaf)); // cascaded
    try testing.expect(game.ecs_backend.entityExists(grandparent));
    try testing.expectEqual(@as(usize, 0), game.getChildren(grandparent).len);

    // Grandparent still healthy after the unlink.
    game.destroyEntity(grandparent);
    try testing.expectEqual(@as(usize, 0), game.entityCount());
}

test "#701: three-level cascade destroys the whole tree" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    // G → M → C. Destroying G runs M's unlink while G is mid-destroy —
    // the parent-side list mutation must not corrupt G's ongoing cascade.
    const grandparent = game.createEntity();
    const middle = game.createEntity();
    const leaf_a = game.createEntity();
    const leaf_b = game.createEntity();
    game.setParent(middle, grandparent, .{});
    game.setParent(leaf_a, middle, .{});
    game.setParent(leaf_b, middle, .{});

    game.destroyEntity(grandparent);

    try testing.expect(!game.ecs_backend.entityExists(grandparent));
    try testing.expect(!game.ecs_backend.entityExists(middle));
    try testing.expect(!game.ecs_backend.entityExists(leaf_a));
    try testing.expect(!game.ecs_backend.entityExists(leaf_b));
    try testing.expectEqual(@as(usize, 0), game.entityCount());
}

test "#701: destroyEntityOnly unlinks from the parent but leaves its own children alive" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const parent = game.createEntity();
    const entity = game.createEntity();
    const child_of_entity = game.createEntity();
    game.setParent(entity, parent, .{});
    game.setParent(child_of_entity, entity, .{});

    game.destroyEntityOnly(entity);

    try testing.expect(!game.ecs_backend.entityExists(entity));
    // Unlinked from the surviving parent.
    try testing.expectEqual(@as(usize, 0), game.getChildren(parent).len);
    // Contract preserved: no cascade — the scene drain that uses this
    // variant destroys every tracked entity itself.
    try testing.expect(game.ecs_backend.entityExists(child_of_entity));
    try testing.expect(game.ecs_backend.entityExists(parent));
}

test "#701: destroyEntityOnly tolerates a parent destroyed earlier in the drain" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const parent = game.createEntity();
    const child = game.createEntity();
    game.setParent(child, parent, .{});

    // The scene drain pops tracked entities in arbitrary (reverse) order,
    // so the parent can die first. The child's unlink must skip the dead
    // parent (entityExists guard) instead of writing through a stale id.
    game.destroyEntityOnly(parent);
    game.destroyEntityOnly(child);

    try testing.expectEqual(@as(usize, 0), game.entityCount());
}

test "#701: re-parent then destroy touches only the current parent's list" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const p1 = game.createEntity();
    const p2 = game.createEntity();
    const sibling = game.createEntity();
    const e = game.createEntity();
    game.setParent(sibling, p1, .{});
    game.setParent(e, p1, .{});
    game.setParent(e, p2, .{}); // move p1 → p2 (setParent unlinks from p1)
    try testing.expect(!childrenContain(&game, p1, e));
    try testing.expect(childrenContain(&game, p2, e));

    game.destroyEntity(e);

    try testing.expectEqual(@as(usize, 1), game.getChildren(p1).len);
    try testing.expect(childrenContain(&game, p1, sibling));
    try testing.expectEqual(@as(usize, 0), game.getChildren(p2).len);
    try testing.expect(game.ecs_backend.entityExists(p1));
    try testing.expect(game.ecs_backend.entityExists(p2));
}

// ── Cascade panic-safety against already-dead descendants ───────────────
//
// A consumer (flying-platform room teardown) wants to cascade-destroy an
// ancestor AFTER having already destroyed some of its descendants directly.
// Before the idempotence guard the cascade re-hit those dead ids: it
// double-freed the heap-backed `Children` list, re-emitted
// `entity_destroyed`, and trapped the backend destroy. These tests pin that
// re-hitting a dead entity anywhere in the walk is a leak-free no-op
// (`testing.allocator` via `game.deinit` fails on any leaked child list).

test "cascade: destroying a subtree whose child was already destroyed is a safe no-op" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const parent = game.createEntity();
    const child_a = game.createEntity();
    const child_b = game.createEntity();
    game.setParent(child_a, parent, .{});
    game.setParent(child_b, parent, .{});

    // Consumer destroys one child up front (it unlinks from parent's list).
    game.destroyEntity(child_a);
    try testing.expect(!game.ecs_backend.entityExists(child_a));

    // Now cascade the ancestor. child_a is already dead — the cascade must
    // NOT re-hit it (double-free / trap). The rest is still cleaned up.
    game.destroyEntity(parent);

    try testing.expect(!game.ecs_backend.entityExists(parent));
    try testing.expect(!game.ecs_backend.entityExists(child_b));
    try testing.expectEqual(@as(usize, 0), game.entityCount());
}

test "cascade: a grandchild destroyed before its parent's cascade is skipped" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    // G → M → L. Kill the leaf first, then cascade the grandparent: the
    // walk descends G → M → L and must early-return on the dead L.
    const grandparent = game.createEntity();
    const middle = game.createEntity();
    const leaf = game.createEntity();
    game.setParent(middle, grandparent, .{});
    game.setParent(leaf, middle, .{});

    game.destroyEntity(leaf);
    try testing.expect(!game.ecs_backend.entityExists(leaf));
    // Middle survives (only the leaf died) and its list is now empty.
    try testing.expect(game.ecs_backend.entityExists(middle));
    try testing.expectEqual(@as(usize, 0), game.getChildren(middle).len);

    // Cascade the whole remaining tree — the dead leaf must not re-trap.
    game.destroyEntity(grandparent);

    try testing.expect(!game.ecs_backend.entityExists(grandparent));
    try testing.expect(!game.ecs_backend.entityExists(middle));
    try testing.expectEqual(@as(usize, 0), game.entityCount());
}

test "cascade: destroying an already-dead entity directly is a no-op" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const bystander = game.createEntity();
    const entity = game.createEntity();

    game.destroyEntity(entity);
    try testing.expect(!game.ecs_backend.entityExists(entity));
    const count_after_first = game.entityCount();

    // A second destroy of the same id must not re-emit hooks, double-free,
    // or disturb the count / the bystander.
    game.destroyEntity(entity);
    try testing.expectEqual(count_after_first, game.entityCount());
    try testing.expect(game.ecs_backend.entityExists(bystander));
}

test "cascade: an already-destroyed subtree with grandchildren does not double-free" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    // parent → mid (→ leaf), and a sibling under parent. Destroy `mid`
    // (cascading leaf) up front, THEN cascade parent. The parent's walk
    // reaches the dead `mid`, which must be skipped whole — its already-
    // freed `Children` list must not be freed again.
    const parent = game.createEntity();
    const mid = game.createEntity();
    const leaf = game.createEntity();
    const sibling = game.createEntity();
    game.setParent(mid, parent, .{});
    game.setParent(leaf, mid, .{});
    game.setParent(sibling, parent, .{});

    game.destroyEntity(mid);
    try testing.expect(!game.ecs_backend.entityExists(mid));
    try testing.expect(!game.ecs_backend.entityExists(leaf)); // cascaded

    game.destroyEntity(parent);
    try testing.expect(!game.ecs_backend.entityExists(parent));
    try testing.expect(!game.ecs_backend.entityExists(sibling));
    try testing.expectEqual(@as(usize, 0), game.entityCount());
}

test "cascade: a normal (all-live) destroy still cleans up and keeps entityCount correct" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const keep_a = game.createEntity();
    const keep_b = game.createEntity();
    const parent = game.createEntity();
    var kids: [3]Entity = undefined;
    for (&kids) |*k| {
        k.* = game.createEntity();
        game.setParent(k.*, parent, .{});
    }
    try testing.expectEqual(@as(usize, 6), game.entityCount());

    game.destroyEntity(parent);

    try testing.expect(!game.ecs_backend.entityExists(parent));
    for (kids) |k| try testing.expect(!game.ecs_backend.entityExists(k));
    // Unrelated entities untouched; count reflects exactly the 4 removed.
    try testing.expect(game.ecs_backend.entityExists(keep_a));
    try testing.expect(game.ecs_backend.entityExists(keep_b));
    try testing.expectEqual(@as(usize, 2), game.entityCount());
}

test "destroyEntityOnly: destroying an already-dead entity is a no-op" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const entity = game.createEntity();
    game.destroyEntityOnly(entity);
    const count_after = game.entityCount();

    // Idempotent second call — no double-free, no duplicate hooks.
    game.destroyEntityOnly(entity);
    try testing.expectEqual(count_after, game.entityCount());
}

test "#701: repeated child destroys don't leak Children slots" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    // Consequence 3 of the bug: a leaked stale id used to linger in the
    // parent's child list after each destroy. With dynamic children there's
    // no cap, so this instead pins that repeated parent+destroy cycles leave
    // the list correct (each destroy unlinks the child) and leak nothing —
    // `testing.allocator` (via `game.deinit`) fails the test on any leaked
    // child-list allocation. Loop well past the old 16 cap.
    const parent = game.createEntity();
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        const child = game.createEntity();
        game.setParent(child, parent, .{});
        game.destroyEntity(child);
    }

    const last = game.createEntity();
    game.setParent(last, parent, .{});
    try testing.expectEqual(@as(usize, 1), game.getChildren(parent).len);
    try testing.expect(childrenContain(&game, parent, last));
}
