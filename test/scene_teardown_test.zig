//! Tests for the scene-teardown fixes (labelle-engine#630):
//!
//!   1. `unloadCurrentScene` drains `scene_entities` in O(N), not
//!      O(N²): the `tearing_down_scene` guard makes the per-entity
//!      `untrackSceneEntity` swap-remove scan a no-op while the drain
//!      pops each entity off the list itself. Behaviour is unchanged —
//!      every tracked entity is still destroyed exactly once and the
//!      `entity_destroyed` hook fires once per entity.
//!
//!   2. `resetEcsBackend` clears `scene_entities` (and the active
//!      scene's own list) so a *direct* call leaves no dangling IDs for
//!      a later `unloadCurrentScene` to feed `destroyEntityOnly` as
//!      invalid handles. Idempotent w.r.t. callers that already clear.
//!
//! Uses the in-tree `GameWith(Hooks)` (MockEcsBackend + StubRender), the
//! same shape `pause_hook_test.zig` and `flows_game_api_test.zig` use.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");

const game_mod = engine.game_mod;

// ── Hook recorder ───────────────────────────────────────────────────────
//
// Records each `entity_destroyed` payload so tests can assert the hook
// fired exactly once per tracked entity (issue 1's behaviour-preservation
// guarantee). The method name must match the hook variant tag —
// mirrors `PauseRecorder` in `pause_hook_test.zig`.

const DestroyRecorder = struct {
    destroyed: std.ArrayListUnmanaged(u32) = .empty,
    allocator: std.mem.Allocator,

    pub fn entity_destroyed(self: *DestroyRecorder, info: anytype) void {
        self.destroyed.append(self.allocator, @intCast(info.entity_id)) catch unreachable;
    }

    pub fn deinit(self: *DestroyRecorder) void {
        self.destroyed.deinit(self.allocator);
    }

    fn count(self: *const DestroyRecorder, id: u32) usize {
        var n: usize = 0;
        for (self.destroyed.items) |d| {
            if (d == id) n += 1;
        }
        return n;
    }
};

const TestGame = game_mod.GameWith(*DestroyRecorder);

// ── Issue 1: O(N) unload destroys every tracked entity exactly once ──────

test "unloadCurrentScene destroys all tracked entities and empties scene_entities" {
    var recorder = DestroyRecorder{ .allocator = testing.allocator };
    defer recorder.deinit();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    game.setHooks(&recorder);

    // Track a batch of entities, exactly as a scene loader would.
    var ids: [8]u32 = undefined;
    for (&ids) |*slot| {
        const e = game.createEntity();
        game.trackSceneEntity(e);
        slot.* = e;
    }
    try testing.expectEqual(@as(usize, 8), game.scene_entities.items.len);

    game.unloadCurrentScene();

    // The tracking list is fully drained.
    try testing.expectEqual(@as(usize, 0), game.scene_entities.items.len);
    // The teardown guard is restored (not left stuck on).
    try testing.expect(!game.tearing_down_scene);

    // Every tracked entity fired its `entity_destroyed` hook EXACTLY once
    // — the O(N) fix must not drop or double-fire any destroy.
    try testing.expectEqual(@as(usize, 8), recorder.destroyed.items.len);
    for (ids) |id| {
        try testing.expectEqual(@as(usize, 1), recorder.count(id));
    }
}

test "unloadCurrentScene on an empty scene is a no-op" {
    var recorder = DestroyRecorder{ .allocator = testing.allocator };
    defer recorder.deinit();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    game.setHooks(&recorder);

    game.unloadCurrentScene();

    try testing.expectEqual(@as(usize, 0), game.scene_entities.items.len);
    try testing.expectEqual(@as(usize, 0), recorder.destroyed.items.len);
    try testing.expect(!game.tearing_down_scene);
}

// The `tearing_down_scene` guard must not leak into normal (non-drain)
// `destroyEntityOnly` calls: a manual destroy still removes the entity
// from `scene_entities` via the O(N) swap-remove path. This pins down
// that the guard is scoped to the drain loop only.
test "manual destroyEntityOnly still untracks the entity (guard is drain-scoped)" {
    var recorder = DestroyRecorder{ .allocator = testing.allocator };
    defer recorder.deinit();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    game.setHooks(&recorder);

    const a = game.createEntity();
    const b = game.createEntity();
    game.trackSceneEntity(a);
    game.trackSceneEntity(b);
    try testing.expectEqual(@as(usize, 2), game.scene_entities.items.len);

    // Outside a drain, the guard is false, so untrackSceneEntity runs its
    // scan and removes `a` from the list.
    try testing.expect(!game.tearing_down_scene);
    game.destroyEntityOnly(a);
    try testing.expectEqual(@as(usize, 1), game.scene_entities.items.len);
    try testing.expectEqual(@as(u32, b), game.scene_entities.items[0]);

    // A subsequent unload cleans up the remaining tracked entity without
    // re-destroying `a` (it's already gone from the list).
    game.unloadCurrentScene();
    try testing.expectEqual(@as(usize, 0), game.scene_entities.items.len);
    try testing.expectEqual(@as(usize, 1), recorder.count(a));
    try testing.expectEqual(@as(usize, 1), recorder.count(b));
}

// ── Issue 2: resetEcsBackend clears scene_entities ──────────────────────

test "resetEcsBackend clears scene_entities" {
    var game = game_mod.Game.init(testing.allocator);
    defer game.deinit();

    // Track some entities, then wipe the ECS directly (no setSceneAtomic /
    // loadGameState pre-clear). Before the fix, these stale IDs would
    // survive and a later unload would destroy them as invalid handles.
    for (0..5) |_| {
        const e = game.createEntity();
        game.trackSceneEntity(e);
    }
    try testing.expectEqual(@as(usize, 5), game.scene_entities.items.len);

    game.resetEcsBackend();

    try testing.expectEqual(@as(usize, 0), game.scene_entities.items.len);
}

test "resetEcsBackend is idempotent on an already-empty scene_entities" {
    var game = game_mod.Game.init(testing.allocator);
    defer game.deinit();

    // Clearing an empty list (the existing setSceneAtomic / loadGameState
    // ordering, which clears up front) must be harmless.
    try testing.expectEqual(@as(usize, 0), game.scene_entities.items.len);
    game.resetEcsBackend();
    try testing.expectEqual(@as(usize, 0), game.scene_entities.items.len);

    // And a second back-to-back reset is fine too.
    game.resetEcsBackend();
    try testing.expectEqual(@as(usize, 0), game.scene_entities.items.len);
}
