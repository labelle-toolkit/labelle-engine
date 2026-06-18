//! Post-load render gate (#637).
//!
//! After `loadGameState` restores entities, the atlases their sprites
//! reference re-decode/re-upload asynchronously — during that window the
//! re-registered atlases sit at `texture_id == 0` and the restored
//! sprites would flash with an unbound / wrong texture. The gate holds
//! the world render until every gated atlas has re-bound.
//!
//! These tests drive the gate primitives directly
//! (`armPostLoadRenderGate` / `updatePostLoadRenderGate`) and manipulate
//! the catalog + atlas_manager state by hand — same approach as
//! `scene_assets_hooks_test.zig`. They target the gate logic in
//! `save_load_mixin.zig`, not the catalog pump or the renderer.

const std = @import("std");
const testing = std.testing;

const engine = @import("engine");
const Game = engine.Game;

fn emptyLoader(_: *Game) anyerror!void {}

/// Register `name` as a `.ready` image catalog entry AND a still-pending
/// atlas_manager atlas (texture_id == 0) — the exact state a
/// just-re-registered atlas is in right after a load, before the bridge
/// wires its real handle in.
fn registerPendingImage(game: *Game, name: []const u8) !void {
    try game.assets.register(name, .image, "png", "stub-bytes");
    const entry = game.assets.entries.getPtr(name).?;
    entry.state = .ready;
    entry.refcount = 1;
    // A pending atlas: JSON parsed, PNG not yet bridged → texture_id 0.
    try game.atlas_manager.registerPendingAtlas(name, "{\"frames\":{}}", "img", "png");
}

/// Flip a pending atlas to bound, mirroring what the per-tick
/// `bridgeAllReadyImageAssets` → `markPendingLoaded` does once the
/// upload lands.
fn bindAtlas(game: *Game, name: []const u8, texture_id: u32) !void {
    try game.atlas_manager.markPendingLoaded(name, texture_id, null);
}

/// Put the game on a scene with the given image manifest so
/// `armPostLoadRenderGate` (which reads `current_scene_name` +
/// `scenes.get`) has something to gate on.
fn enterScene(game: *Game, comptime name: []const u8, manifest: []const []const u8) void {
    game.registerSceneWithAssets(name, emptyLoader, manifest);
    game.current_scene_name = game.allocator.dupe(u8, name) catch unreachable;
}

test "gate arms when the loaded scene declares a still-pending image atlas" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const manifest: []const []const u8 = &.{ "characters", "cloud" };
    try registerPendingImage(&game, "characters");
    try registerPendingImage(&game, "cloud");
    enterScene(&game, "main", manifest);

    game.armPostLoadRenderGate();

    // Gate is armed — render must be suppressed.
    try testing.expect(game.post_load_render_gate != null);
}

test "gate clears once every gated atlas has re-bound" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const manifest: []const []const u8 = &.{ "characters", "cloud" };
    try registerPendingImage(&game, "characters");
    try registerPendingImage(&game, "cloud");
    enterScene(&game, "main", manifest);

    game.armPostLoadRenderGate();
    try testing.expect(game.post_load_render_gate != null);

    // Only one atlas bound — gate must STILL hold (the other is unbound,
    // texture_id 0; un-hiding now is exactly the corruption flash).
    try bindAtlas(&game, "characters", 7);
    game.updatePostLoadRenderGate();
    try testing.expect(game.post_load_render_gate != null);

    // Both bound — gate clears this frame.
    try bindAtlas(&game, "cloud", 9);
    game.updatePostLoadRenderGate();
    try testing.expect(game.post_load_render_gate == null);
}

test "gate does not arm for an empty manifest" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    enterScene(&game, "main", &.{});
    game.armPostLoadRenderGate();
    try testing.expect(game.post_load_render_gate == null);
}

test "gate does not arm for a non-image (audio-only) manifest" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const manifest: []const []const u8 = &.{"theme"};
    try game.assets.register("theme", .audio, "ogg", "stub-bytes");
    game.assets.entries.getPtr("theme").?.state = .ready;
    enterScene(&game, "main", manifest);

    game.armPostLoadRenderGate();
    try testing.expect(game.post_load_render_gate == null);
}

test "a .failed atlas is terminal — gate does not wedge on it" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const manifest: []const []const u8 = &.{ "characters", "broken" };
    try registerPendingImage(&game, "characters");
    // `broken` is an image asset that failed to decode — treated as
    // terminal so the gate doesn't hold the world forever.
    try game.assets.register("broken", .image, "png", "stub");
    const broken = game.assets.entries.getPtr("broken").?;
    broken.state = .failed;
    broken.last_error = error.TestInjectedFailure;
    enterScene(&game, "main", manifest);

    game.armPostLoadRenderGate();
    try testing.expect(game.post_load_render_gate != null);

    // `broken` is `.failed` (skipped); once `characters` binds the gate
    // clears even though `broken` never reached `.ready`.
    try bindAtlas(&game, "characters", 7);
    game.updatePostLoadRenderGate();
    try testing.expect(game.post_load_render_gate == null);
}

test "gate clears at the frame deadline even if an atlas never binds" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const manifest: []const []const u8 = &.{"characters"};
    try registerPendingImage(&game, "characters");
    enterScene(&game, "main", manifest);

    game.armPostLoadRenderGate();
    try testing.expect(game.post_load_render_gate != null);

    // Atlas never binds. Before the deadline the gate holds.
    game.updatePostLoadRenderGate();
    try testing.expect(game.post_load_render_gate != null);

    // Jump past the deadline — the gate force-clears so the world can
    // never freeze permanently.
    game.frame_number = game.post_load_render_gate_deadline;
    game.updatePostLoadRenderGate();
    try testing.expect(game.post_load_render_gate == null);
}

test "an atlas bound at texture_id 0 is ready (bgfx valid-handle case)" {
    // Regression guard: `texture_id == 0` is the *pending* sentinel only
    // while an atlas is registered-but-not-decoded. Once decoded, 0 is a
    // valid backend handle (bgfx binds the FP `characters` atlas at 0).
    // The gate must treat a decoded atlas as ready REGARDLESS of its
    // handle value — gating on `texture_id != 0` would hold the gate
    // open until the deadline on every load.
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const manifest: []const []const u8 = &.{"characters"};
    try registerPendingImage(&game, "characters");
    enterScene(&game, "main", manifest);

    game.armPostLoadRenderGate();
    try testing.expect(game.post_load_render_gate != null);

    // Decode lands and the atlas binds at handle 0 — a valid, ready
    // texture. The gate must clear (not wait for a non-zero handle).
    try bindAtlas(&game, "characters", 0);
    game.updatePostLoadRenderGate();
    try testing.expect(game.post_load_render_gate == null);
}

test "a catalog image still decoding holds the gate" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const manifest: []const []const u8 = &.{"characters"};
    try game.assets.register("characters", .image, "png", "stub");
    game.assets.entries.getPtr("characters").?.state = .decoding;
    try game.atlas_manager.registerPendingAtlas("characters", "{\"frames\":{}}", "img", "png");
    enterScene(&game, "main", manifest);

    game.armPostLoadRenderGate();
    // Still decoding → not ready → gate holds.
    game.updatePostLoadRenderGate();
    try testing.expect(game.post_load_render_gate != null);

    // Decode lands + atlas bridges → gate clears.
    game.assets.entries.getPtr("characters").?.state = .ready;
    try bindAtlas(&game, "characters", 3);
    game.updatePostLoadRenderGate();
    try testing.expect(game.post_load_render_gate == null);
}
