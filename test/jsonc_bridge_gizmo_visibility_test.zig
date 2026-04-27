// Regression tests for #494 — gizmo visibility toggling.
//
// Verifies that `JsoncSceneBridgeWithGizmos.reconcileGizmos`:
//   - flips Gizmo entity visibility on `setGizmosEnabled` transitions, and
//   - leaves author-set `visible = false` gizmos hidden across cycles
//     (per-entity preservation — the bug this PR fixes).
//
// Drives the bridge directly (no JSONC scene) by manually creating
// `Gizmo`-tagged entities and calling `reconcileGizmos`. The default
// `engine.Game` carries an empty component registry, and `NoGizmos`
// keeps the per-gizmo create pass a no-op so the test isolates
// `syncGizmoVisibility` behaviour.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const core = @import("labelle-core");

const Game = engine.Game;
const Entity = Game.EntityType;
const Sprite = Game.SpriteComp;
const Gizmo = core.GizmoComponent(Entity);

const Bridge = engine.JsoncSceneBridgeWithGizmos(
    Game,
    Game.ComponentRegistry,
    engine.NoGizmos,
);

fn spawnGizmoSprite(game: *Game, parent: Entity, visible: bool) Entity {
    const e = game.createEntity();
    game.ecs_backend.addComponent(e, Gizmo{
        .parent_entity = parent,
        .offset_x = 0,
        .offset_y = 0,
    });
    game.setPosition(e, .{ .x = 0, .y = 0 });
    game.addSprite(e, .{ .sprite_name = "g", .visible = visible });
    return e;
}

test "gizmo visibility: toggle hides then restores" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const parent = game.createEntity();
    game.setPosition(parent, .{ .x = 0, .y = 0 });
    const gz = spawnGizmoSprite(&game, parent, true);

    // First reconcile: starting state = enabled, no transition yet.
    Bridge.reconcileGizmos(&game);
    try testing.expect(game.getComponent(gz, Sprite).?.visible);

    // Disable → next reconcile flips visible=false.
    game.setGizmosEnabled(false);
    Bridge.reconcileGizmos(&game);
    try testing.expect(!game.getComponent(gz, Sprite).?.visible);

    // Re-enable → reconcile restores visible=true.
    game.setGizmosEnabled(true);
    Bridge.reconcileGizmos(&game);
    try testing.expect(game.getComponent(gz, Sprite).?.visible);
}

test "gizmo visibility: author-set hidden survives toggle cycle" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const parent = game.createEntity();
    game.setPosition(parent, .{ .x = 0, .y = 0 });
    const author_hidden = spawnGizmoSprite(&game, parent, false);
    const author_shown = spawnGizmoSprite(&game, parent, true);

    // Initial reconcile while enabled.
    Bridge.reconcileGizmos(&game);
    try testing.expect(!game.getComponent(author_hidden, Sprite).?.visible);
    try testing.expect(game.getComponent(author_shown, Sprite).?.visible);

    // Disable: shown entity hides; author-hidden was already hidden
    // (no state change either way).
    game.setGizmosEnabled(false);
    Bridge.reconcileGizmos(&game);
    try testing.expect(!game.getComponent(author_hidden, Sprite).?.visible);
    try testing.expect(!game.getComponent(author_shown, Sprite).?.visible);

    // Re-enable: only the entity we forced hidden gets restored.
    // The author-hidden one must stay hidden — that's the
    // per-entity preservation behaviour Copilot flagged on #494.
    game.setGizmosEnabled(true);
    Bridge.reconcileGizmos(&game);
    try testing.expect(!game.getComponent(author_hidden, Sprite).?.visible);
    try testing.expect(game.getComponent(author_shown, Sprite).?.visible);
}

// Mirrors what `createGizmoEntities` does internally when a gizmo
// is spawned while the global toggle is OFF: an author-shown gizmo
// gets flipped to hidden and tagged so a later enable can restore
// it. Driven through the public sync path here (spawn visible=true
// while disabled → first sync hides + tags) rather than exercising
// `createGizmoEntities` directly, since that path is private and
// requires a configured `GizmoReg`. The visible-state contract is
// what the bug is about, and that's what we assert.
test "gizmo visibility: author-shown spawned while disabled is restored on enable" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    game.setGizmosEnabled(false);

    const parent = game.createEntity();
    game.setPosition(parent, .{ .x = 0, .y = 0 });
    const gz = spawnGizmoSprite(&game, parent, true);

    Bridge.reconcileGizmos(&game);
    try testing.expect(!game.getComponent(gz, Sprite).?.visible);

    game.setGizmosEnabled(true);
    Bridge.reconcileGizmos(&game);
    try testing.expect(game.getComponent(gz, Sprite).?.visible);
}

// Counterpart: a gizmo authored as `visible = false` should never
// be unhidden by a global toggle, even if the entity was created
// while the global was OFF. This is the case `createGizmoEntities`
// previously fumbled — it tagged everything with
// `GizmoForcedHidden` on disabled-spawn, so the next enable would
// erroneously show author-hidden gizmos (cursor HIGH on #494).
test "gizmo visibility: author-hidden spawned while disabled stays hidden on enable" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    game.setGizmosEnabled(false);

    const parent = game.createEntity();
    game.setPosition(parent, .{ .x = 0, .y = 0 });
    const gz = spawnGizmoSprite(&game, parent, false);

    Bridge.reconcileGizmos(&game);
    try testing.expect(!game.getComponent(gz, Sprite).?.visible);

    game.setGizmosEnabled(true);
    Bridge.reconcileGizmos(&game);
    try testing.expect(!game.getComponent(gz, Sprite).?.visible);
}

// Regression for cursor MEDIUM on #494: an earlier revision tracked
// the previous `gizmos_enabled` state in a per-bridge module-level
// `var`, which survived `Game.deinit` → `Game.init`. The new
// instance would then read a stale `last == target` and skip the
// first sync. With the static dropped, two separate Game instances
// each sync correctly from scratch.
test "gizmo visibility: fresh game instance is not poisoned by previous one" {
    {
        var game = Game.init(testing.allocator);
        defer game.deinit();
        const parent = game.createEntity();
        game.setPosition(parent, .{ .x = 0, .y = 0 });
        _ = spawnGizmoSprite(&game, parent, true);
        game.setGizmosEnabled(false);
        Bridge.reconcileGizmos(&game);
    }

    var game2 = Game.init(testing.allocator);
    defer game2.deinit();
    const parent = game2.createEntity();
    game2.setPosition(parent, .{ .x = 0, .y = 0 });
    const gz = spawnGizmoSprite(&game2, parent, true);

    // game2 starts enabled by default — first sync should leave
    // visible=true. If the bridge had stale state claiming "last
    // = false" from game1, it would consider this a no-op
    // transition and the visible flag could be wrong; with the
    // static dropped, the marker-less view is empty and visible
    // stays true.
    Bridge.reconcileGizmos(&game2);
    try testing.expect(game2.getComponent(gz, Sprite).?.visible);

    // Disable on game2 should still flip the entity even though
    // game1 ended in a disabled state.
    game2.setGizmosEnabled(false);
    Bridge.reconcileGizmos(&game2);
    try testing.expect(!game2.getComponent(gz, Sprite).?.visible);
}
