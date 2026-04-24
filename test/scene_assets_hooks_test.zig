//! Scene asset hooks + `asset_failure_policy` (issue #444).
//!
//! Exercises:
//!   1. `scene_assets_acquire` and `scene_assets_release` fire with the
//!      right name/manifest payloads and in the right relative order.
//!   2. `Game.asset_failure_policy` — `.fatal` rolls back + bubbles the
//!      error, `.warn` / `.silent` swallow and let `setScene` proceed.
//!
//! Asset worker state is manipulated directly via `catalog.entries`
//! rather than driven through the real loader — these tests target
//! the hook wiring in `scene_mixin.zig`, not the catalog pump.

const std = @import("std");
const testing = std.testing;

const engine = @import("engine");
const Game = engine.Game;
const GameWith = engine.GameWith;
const AssetState = engine.AssetState;
const LoaderKind = engine.LoaderKind;

fn emptyLoader(_: *Game) anyerror!void {}
fn emptyLoaderRec(_: *GameWith(*RecordingHooks)) anyerror!void {}

// ── Hook wiring tests ────────────────────────────────────────────────

const HookEvent = struct {
    kind: enum { acquire, release, before_reset, before_load, load },
    name: []u8,
    assets_len: usize,
};

const RecordingHooks = struct {
    events: std.ArrayList(HookEvent) = .{},
    allocator: std.mem.Allocator,

    fn deinit(self: *RecordingHooks) void {
        for (self.events.items) |ev| self.allocator.free(ev.name);
        self.events.deinit(self.allocator);
    }

    fn push(self: *RecordingHooks, kind: anytype, name: []const u8, assets_len: usize) void {
        const dup = self.allocator.dupe(u8, name) catch return;
        self.events.append(self.allocator, .{ .kind = kind, .name = dup, .assets_len = assets_len }) catch {};
    }

    pub fn scene_assets_acquire(self: *@This(), info: anytype) void {
        self.push(.acquire, info.name, info.assets.len);
    }
    pub fn scene_assets_release(self: *@This(), info: anytype) void {
        self.push(.release, info.name, info.assets.len);
    }
    pub fn scene_before_reset(self: *@This(), info: anytype) void {
        self.push(.before_reset, info.name, 0);
    }
    pub fn scene_before_load(self: *@This(), info: anytype) void {
        self.push(.before_load, info.name, 0);
    }
    pub fn scene_load(self: *@This(), info: anytype) void {
        self.push(.load, info.name, 0);
    }
};

test "scene_assets_acquire/release: fire with name + manifest payload" {
    var hooks = RecordingHooks{ .allocator = testing.allocator };
    defer hooks.deinit();

    var game = GameWith(*RecordingHooks).init(testing.allocator);
    defer game.deinit();
    game.setHooks(&hooks);

    // Empty manifests — the gate proceeds immediately. We only
    // want to prove the acquire hook fires with the target's
    // manifest (even if empty) at the right point in the flow.
    game.registerSceneSimple("first", emptyLoaderRec);
    game.registerSceneSimple("second", emptyLoaderRec);

    try game.setScene("first");
    try game.setScene("second");

    // Expected sequence across both swaps:
    //   first:  acquire(first) → before_load(first) → load(first)
    //   second: acquire(second) → before_load(second) → load(second) → release(first)
    const events = hooks.events.items;
    try testing.expectEqual(@as(usize, 7), events.len);

    try testing.expectEqual(.acquire, events[0].kind);
    try testing.expectEqualStrings("first", events[0].name);
    try testing.expectEqual(.before_load, events[1].kind);
    try testing.expectEqual(.load, events[2].kind);

    try testing.expectEqual(.acquire, events[3].kind);
    try testing.expectEqualStrings("second", events[3].name);
    try testing.expectEqual(.before_load, events[4].kind);
    try testing.expectEqual(.load, events[5].kind);

    try testing.expectEqual(.release, events[6].kind);
    try testing.expectEqualStrings("first", events[6].name);
}

test "scene_assets_acquire: payload carries the manifest slice" {
    var hooks = RecordingHooks{ .allocator = testing.allocator };
    defer hooks.deinit();

    var game = GameWith(*RecordingHooks).init(testing.allocator);
    defer game.deinit();
    game.setHooks(&hooks);

    // Register with a manifest and force its entries to `.ready`
    // so the gate proceeds without running the real worker.
    const manifest: []const []const u8 = &.{ "ship", "background" };
    game.registerSceneWithAssets("level", emptyLoaderRec, manifest);

    for (manifest) |name| {
        try game.assets.register(name, .image, "png", "stub-bytes");
        const entry = game.assets.entries.getPtr(name).?;
        entry.state = .ready;
        entry.refcount = 0;
    }

    try game.setScene("level");

    // First event must be acquire with both asset names.
    try testing.expectEqual(.acquire, hooks.events.items[0].kind);
    try testing.expectEqualStrings("level", hooks.events.items[0].name);
    try testing.expectEqual(@as(usize, 2), hooks.events.items[0].assets_len);
}

// ── Failure-policy tests ─────────────────────────────────────────────

fn registerFailedAsset(game: *Game, name: []const u8) !void {
    try game.assets.register(name, .image, "png", "stub");
    const entry = game.assets.entries.getPtr(name).?;
    entry.state = .failed;
    entry.last_error = error.TestInjectedFailure;
}

test "asset_failure_policy.fatal: setScene returns the load error" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const manifest: []const []const u8 = &.{"broken"};
    game.registerSceneWithAssets("level", emptyLoader, manifest);
    try registerFailedAsset(&game, "broken");

    // Default is `.fatal`.
    try testing.expectEqual(Game.AssetFailurePolicy.fatal, game.asset_failure_policy);
    try testing.expectError(error.TestInjectedFailure, game.setScene("level"));

    // Rollback happened — no pending marker leaked, refcount not
    // left incremented on the broken asset (it never was, but
    // anyone else acquired during the batch must have been released).
    try testing.expectEqual(@as(?[]const u8, null), game.pending_scene_assets);
}

test "asset_failure_policy.warn: setScene swallows the failure and proceeds" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    game.asset_failure_policy = .warn;

    const manifest: []const []const u8 = &.{"broken"};
    game.registerSceneWithAssets("level", emptyLoader, manifest);
    try registerFailedAsset(&game, "broken");

    try game.setScene("level");

    // Swap committed despite the broken asset.
    try testing.expectEqualStrings("level", game.getCurrentSceneName().?);
}

test "asset_failure_policy.silent: setScene swallows without logging" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    game.asset_failure_policy = .silent;

    const manifest: []const []const u8 = &.{"broken"};
    game.registerSceneWithAssets("level", emptyLoader, manifest);
    try registerFailedAsset(&game, "broken");

    try game.setScene("level");
    try testing.expectEqualStrings("level", game.getCurrentSceneName().?);
}

test "asset_failure_policy.warn: defers swap while other manifest assets are still in-flight" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    game.asset_failure_policy = .warn;

    const manifest: []const []const u8 = &.{ "broken", "still_loading" };
    game.registerSceneWithAssets("level", emptyLoader, manifest);
    try registerFailedAsset(&game, "broken");

    // `still_loading` is registered but stuck in an in-flight
    // state — simulates an asset the real worker hasn't finished.
    try game.assets.register("still_loading", .image, "png", "stub");
    const loading = game.assets.entries.getPtr("still_loading").?;
    loading.state = .queued;

    try game.setScene("level");
    // Swap deferred — `broken` is .failed (OK under .warn) but
    // `still_loading` hasn't reached .ready or .failed yet.
    try testing.expectEqual(@as(?[]const u8, null), game.getCurrentSceneName());

    // Move `still_loading` to a terminal state — swap unblocks.
    loading.state = .ready;
    try game.setScene("level");
    try testing.expectEqualStrings("level", game.getCurrentSceneName().?);
}

test "acquire error bypasses asset_failure_policy (always fatal)" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    game.asset_failure_policy = .silent; // even under .silent…

    // Reference an asset name that was never registered with the
    // catalog. `acquire` fails with `error.AssetNotRegistered`
    // (or similar) — that's an acquire_error path, not an
    // asset_error, and must bubble regardless of policy.
    const manifest: []const []const u8 = &.{"unregistered_asset"};
    game.registerSceneWithAssets("level", emptyLoader, manifest);

    try testing.expectError(error.AssetNotRegistered, game.setScene("level"));
    try testing.expectEqual(@as(?[]const u8, null), game.pending_scene_assets);
}

test "scene_before_reset: fires on setSceneAtomic before the ECS wipe" {
    // Regression guard for labelle-toolkit/flying-platform-labelle#290.
    // `setSceneAtomic` destroys the singleton ECS entities that
    // plugin controllers anchor their heap state on; without a
    // hook fired BEFORE the reset, those heap allocations leak
    // and downstream `.apply` calls hit a null `findState`. The
    // scene_before_reset event gives listeners a last chance to
    // free their state while the singleton still exists.
    var hooks = RecordingHooks{ .allocator = testing.allocator };
    defer hooks.deinit();

    var game = GameWith(*RecordingHooks).init(testing.allocator);
    defer game.deinit();
    game.setHooks(&hooks);

    game.registerSceneSimple("first", emptyLoaderRec);
    game.registerSceneSimple("second", emptyLoaderRec);

    // Set initial scene via non-atomic setScene — does NOT fire
    // before_reset, so the baseline event stream is just
    // acquire/before_load/load as usual.
    try game.setScene("first");

    // Now swap to "second" via setSceneAtomic — the path F8 uses
    // in flying-platform-labelle via `queueSceneChangeAtomic`.
    try game.setSceneAtomic("second");

    // Scan the event log for before_reset. It must fire EXACTLY
    // once for the atomic swap, carrying the NAME of the scene
    // that's about to be torn down ("first" in this case, because
    // we're about to replace it). Counting (rather than just
    // "saw at least one") is the tighter assertion: if a future
    // refactor accidentally broadens the emit surface and fires
    // the hook twice per atomic swap, plugin-controller listeners
    // would double-free their heap state, and this test would
    // stop catching it if we only checked "did it fire."
    var before_reset_count: usize = 0;
    var before_reset_name: []const u8 = "";
    var before_reset_index: usize = 0;
    var before_load_index: usize = 0;

    for (hooks.events.items, 0..) |ev, i| {
        switch (ev.kind) {
            .before_reset => {
                before_reset_count += 1;
                before_reset_name = ev.name;
                before_reset_index = i;
            },
            .before_load => {
                // Track the LAST before_load — the one from the
                // atomic swap, which should come AFTER before_reset.
                before_load_index = i;
            },
            else => {},
        }
    }

    try testing.expectEqual(@as(usize, 1), before_reset_count);
    try testing.expectEqualStrings("first", before_reset_name);

    // before_reset must strictly precede the atomic swap's
    // before_load — that's the whole contract listeners rely on.
    // A plugin controller deinit'ing on before_reset would crash
    // if the ordering flipped (entities already gone when deinit
    // runs).
    try testing.expect(before_reset_index < before_load_index);
}

test "scene_before_reset: does NOT fire on non-atomic setScene" {
    // setScene (non-atomic) destroys entities individually via
    // unloadCurrentScene rather than `resetEcsBackend`, so there's
    // no "atomic wipe" moment to bracket and plugin controllers
    // don't need the pre-reset deinit. Emitting the hook here
    // would be wrong — listeners would free state that's about
    // to be individually destroyed through the normal entity-
    // destroyed path.
    var hooks = RecordingHooks{ .allocator = testing.allocator };
    defer hooks.deinit();

    var game = GameWith(*RecordingHooks).init(testing.allocator);
    defer game.deinit();
    game.setHooks(&hooks);

    game.registerSceneSimple("first", emptyLoaderRec);
    game.registerSceneSimple("second", emptyLoaderRec);

    try game.setScene("first");
    try game.setScene("second");

    for (hooks.events.items) |ev| {
        try testing.expect(ev.kind != .before_reset);
    }
}

test "scene_before_reset: does NOT fire on first atomic swap (no outgoing scene)" {
    // Copilot L367 guard: firing with an empty-string name forces
    // name-keyed listeners to handle an ambiguous sentinel. The
    // contract is "only emit when there's actually something to
    // tear down" — a brand-new Game with no prior setScene has
    // nothing to signal a reset for.
    var hooks = RecordingHooks{ .allocator = testing.allocator };
    defer hooks.deinit();

    var game = GameWith(*RecordingHooks).init(testing.allocator);
    defer game.deinit();
    game.setHooks(&hooks);

    game.registerSceneSimple("first", emptyLoaderRec);

    // First ever scene call — via the atomic path. No prior
    // scene exists, so scene_before_reset should NOT fire.
    try game.setSceneAtomic("first");

    for (hooks.events.items) |ev| {
        try testing.expect(ev.kind != .before_reset);
    }
}
