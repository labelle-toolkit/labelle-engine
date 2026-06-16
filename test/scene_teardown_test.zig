//! Tests for the scene-teardown fixes (labelle-engine#630):
//!
//!   1. `unloadCurrentScene` drains `scene_entities` in O(N), not
//!      O(N²): `untrackSceneEntity` skips its swap-remove scan only for
//!      the one entity currently being popped (`current_teardown_entity`),
//!      while the drain pops each off the list itself. Behaviour is
//!      unchanged — every tracked entity is still destroyed exactly once
//!      and the hook fires once per entity — AND a hook that destroys a
//!      *sibling* tracked entity still untracks it, so it is never
//!      popped+destroyed twice.
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
    try testing.expect(game.current_teardown_entity == null);

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
    try testing.expect(game.current_teardown_entity == null);
}

// The teardown marker must not leak into normal (non-drain)
// `destroyEntityOnly` calls: a manual destroy still removes the entity
// from `scene_entities` via the O(N) swap-remove path. This pins down
// that the skip is scoped to the drain loop only.
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
    try testing.expect(game.current_teardown_entity == null);
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

// The crux of the per-entity (not global) skip: during a drain, only the
// entity currently being popped skips its untrack scan. A DIFFERENT tracked
// entity — e.g. a sibling destroyed re-entrantly by the current entity's
// `entity_destroyed` hook — must STILL untrack, or the drain would pop it a
// second time and `destroyEntityOnly` it as an invalid handle (the bug a
// global flag would reintroduce).
test "untrackSceneEntity skips only the drained entity, not siblings" {
    var recorder = DestroyRecorder{ .allocator = testing.allocator };
    defer recorder.deinit();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    game.setHooks(&recorder);

    const a = game.createEntity();
    const b = game.createEntity();
    const c = game.createEntity();
    game.trackSceneEntity(a);
    game.trackSceneEntity(b);
    game.trackSceneEntity(c);

    // Simulate being mid-drain of `a` (what the drain loop sets).
    game.current_teardown_entity = a;

    // Untracking `a` is the wasteful self-scan the fix skips — `a` stays.
    game.untrackSceneEntity(a);
    try testing.expectEqual(@as(usize, 3), game.scene_entities.items.len);

    // Untracking a sibling (`b`) MUST still remove it, so the drain won't
    // pop+destroy it again.
    game.untrackSceneEntity(b);
    try testing.expectEqual(@as(usize, 2), game.scene_entities.items.len);
    for (game.scene_entities.items) |e| try testing.expect(e != b);

    game.current_teardown_entity = null;
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
