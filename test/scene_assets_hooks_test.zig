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
    kind: enum { acquire, release, before_load, load },
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
