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

    game.armPostLoadRenderGate(null);

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

    game.armPostLoadRenderGate(null);
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
    game.armPostLoadRenderGate(null);
    try testing.expect(game.post_load_render_gate == null);
}

test "gate does not arm for a non-image (audio-only) manifest" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const manifest: []const []const u8 = &.{"theme"};
    try game.assets.register("theme", .audio, "ogg", "stub-bytes");
    game.assets.entries.getPtr("theme").?.state = .ready;
    enterScene(&game, "main", manifest);

    game.armPostLoadRenderGate(null);
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

    game.armPostLoadRenderGate(null);
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

    game.armPostLoadRenderGate(null);
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

    game.armPostLoadRenderGate(null);
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

    game.armPostLoadRenderGate(null);
    // Still decoding → not ready → gate holds.
    game.updatePostLoadRenderGate();
    try testing.expect(game.post_load_render_gate != null);

    // Decode lands + atlas bridges → gate clears.
    game.assets.entries.getPtr("characters").?.state = .ready;
    try bindAtlas(&game, "characters", 3);
    game.updatePostLoadRenderGate();
    try testing.expect(game.post_load_render_gate == null);
}

// ── engine#638: saved-scene manifest + atomic, acquire-and-bridge ──────

/// Register `name` as a fully-uploaded image: `.ready` catalog entry
/// carrying a real `resource` handle (so the gate's atomic bridge can
/// read it) AND a still-pending atlas_manager atlas (texture_id 0). This
/// is the post-decode state the load gate is meant to bind in one pass.
fn registerUploadedImage(game: *Game, name: []const u8, handle: u32) !void {
    try game.assets.register(name, .image, "png", "stub-bytes");
    const entry = game.assets.entries.getPtr(name).?;
    entry.state = .ready;
    entry.refcount = 1;
    entry.resource = .{ .image = handle };
    try game.atlas_manager.registerPendingAtlas(name, "{\"frames\":{}}", "img", "png");
}

test "gate prefers the SAVED scene's manifest over the active scene (#638)" {
    // A menu→Load restores a colony save while the active scene is still
    // `menu`. The gate must arm on the SAVED scene's manifest (the atlases
    // the restored sprites sample from), not the menu's.
    var game = Game.init(testing.allocator);
    defer game.deinit();

    // Active scene = menu (one atlas, already bound — nothing to wait on).
    try registerUploadedImage(&game, "background", 0);
    try bindAtlas(&game, "background", 0);
    enterScene(&game, "menu", &.{"background"});

    // Saved (colony) scene declares two atlases that are still decoding
    // (so the gate holds and we can inspect which manifest it armed on).
    try registerUploadedImage(&game, "characters", 5);
    try registerUploadedImage(&game, "rooms", 6);
    game.assets.entries.getPtr("characters").?.state = .decoding;
    game.assets.entries.getPtr("rooms").?.state = .decoding;
    game.registerSceneWithAssets("colony", emptyLoader, &.{ "characters", "rooms" });

    // Arm against the SAVED scene name — the gate must pick the colony
    // manifest, see two still-unbound atlases, and hold.
    game.armPostLoadRenderGate("colony");
    try testing.expect(game.post_load_render_gate != null);
    // It armed on the colony manifest, not menu's single `background`.
    try testing.expectEqual(@as(usize, 2), game.post_load_render_gate.?.len);
}

test "gate binds the whole manifest atomically in one pass (#638)" {
    // The defining property of the deterministic load gate: it does NOT
    // bind any atlas until EVERY atlas in the manifest is `.ready`, then
    // binds them all in a single `bridgeManifest` pass. A half-ready
    // manifest leaves NOTHING bound (no incremental half-bound window).
    var game = Game.init(testing.allocator);
    defer game.deinit();

    try registerUploadedImage(&game, "characters", 5);
    try registerUploadedImage(&game, "rooms", 6);
    // Start both still decoding so the immediate settle in
    // `armPostLoadRenderGate` can't clear the gate before we test it.
    game.assets.entries.getPtr("characters").?.state = .decoding;
    game.assets.entries.getPtr("rooms").?.state = .decoding;
    game.registerSceneWithAssets("colony", emptyLoader, &.{ "characters", "rooms" });
    game.current_scene_name = game.allocator.dupe(u8, "colony") catch unreachable;

    game.armPostLoadRenderGate("colony");
    try testing.expect(game.post_load_render_gate != null);

    // Make only ONE atlas ready; the other is still decoding.
    game.assets.entries.getPtr("characters").?.state = .ready;
    game.updatePostLoadRenderGate();
    // Nothing should be bound yet — the manifest is bound all-at-once or
    // not at all. `characters` (ready) must still be pending in the
    // manager because the gate refused to bind a half-ready manifest.
    try testing.expect(!game.post_load_render_gate_bridged);
    try testing.expect(!game.atlas_manager.getAtlas("characters").?.isLoaded());
    try testing.expect(game.post_load_render_gate != null);

    // Now the second atlas finishes — the gate binds BOTH in one pass and
    // clears. Each atlas takes the handle its own catalog `resource` holds.
    game.assets.entries.getPtr("rooms").?.state = .ready;
    game.updatePostLoadRenderGate();
    try testing.expect(game.post_load_render_gate_bridged);
    try testing.expect(game.atlas_manager.getAtlas("characters").?.isLoaded());
    try testing.expect(game.atlas_manager.getAtlas("rooms").?.isLoaded());
    try testing.expectEqual(@as(u32, 5), game.atlas_manager.getAtlas("characters").?.texture_id);
    try testing.expectEqual(@as(u32, 6), game.atlas_manager.getAtlas("rooms").?.texture_id);
    try testing.expect(game.post_load_render_gate == null);
}

test "gate acquires the manifest's atlases so the load triggers decode (#638)" {
    // loadGameState must be self-contained: arming the gate acquires the
    // manifest's image atlases (0→1 refcount) so their decode is enqueued
    // by the engine — no external `assets.acquire(...)` workaround needed.
    var game = Game.init(testing.allocator);
    defer game.deinit();

    // A fresh, never-acquired atlas (refcount 0, registered).
    try game.assets.register("characters", .image, "png", "stub");
    try game.atlas_manager.registerPendingAtlas("characters", "{\"frames\":{}}", "img", "png");
    game.registerSceneWithAssets("colony", emptyLoader, &.{"characters"});

    try testing.expectEqual(@as(u32, 0), game.assets.entries.getPtr("characters").?.refcount);
    game.armPostLoadRenderGate("colony");
    // The gate acquired it — refcount bumped to 1.
    try testing.expectEqual(@as(u32, 1), game.assets.entries.getPtr("characters").?.refcount);
}

test "repeated loads release the prior manifest — no refcount leak (#638)" {
    // Load save A's scene, then save B's scene. The acquire from the
    // first arm must be released before the second arm acquires, so each
    // atlas's refcount reflects only the manifest currently pinned.
    var game = Game.init(testing.allocator);
    defer game.deinit();

    try game.assets.register("a_only", .image, "png", "stub");
    try game.atlas_manager.registerPendingAtlas("a_only", "{\"frames\":{}}", "img", "png");
    try game.assets.register("shared", .image, "png", "stub");
    try game.atlas_manager.registerPendingAtlas("shared", "{\"frames\":{}}", "img", "png");
    try game.assets.register("b_only", .image, "png", "stub");
    try game.atlas_manager.registerPendingAtlas("b_only", "{\"frames\":{}}", "img", "png");

    game.registerSceneWithAssets("scene_a", emptyLoader, &.{ "a_only", "shared" });
    game.registerSceneWithAssets("scene_b", emptyLoader, &.{ "shared", "b_only" });

    // Load A.
    game.armPostLoadRenderGate("scene_a");
    try testing.expectEqual(@as(u32, 1), game.assets.entries.getPtr("a_only").?.refcount);
    try testing.expectEqual(@as(u32, 1), game.assets.entries.getPtr("shared").?.refcount);

    // Load B — A's `a_only` is released, B's `b_only` acquired, and
    // `shared` (in both) ends at refcount 1, NOT 2 (released then re-acquired).
    game.armPostLoadRenderGate("scene_b");
    try testing.expectEqual(@as(u32, 0), game.assets.entries.getPtr("a_only").?.refcount);
    try testing.expectEqual(@as(u32, 1), game.assets.entries.getPtr("shared").?.refcount);
    try testing.expectEqual(@as(u32, 1), game.assets.entries.getPtr("b_only").?.refcount);

    // Tearing the game down releases B's manifest too (deinit hook).
    game.releaseLoadAcquired();
    try testing.expectEqual(@as(u32, 0), game.assets.entries.getPtr("shared").?.refcount);
    try testing.expectEqual(@as(u32, 0), game.assets.entries.getPtr("b_only").?.refcount);
}
