//! Sprite-based asset inference wired into the scene-load path (#563).
//!
//! Proves the acceptance criterion of the #563 follow-up: a scene that
//! declares NO `meta.assets` but references a sprite via a `Sprite` component
//! loads the *inferred* asset set — while a scene that DOES declare an explicit
//! manifest is left byte-for-byte unchanged (inference never runs for it).
//!
//! The wiring under test lives in `src/game/scene_mixin.zig`
//! (`resolveSceneAssets` / `ensureReverseIndex` / `setSceneSource`) on top of
//! the reverse-index + walker core in `src/asset_manifest.zig`.

const std = @import("std");
const testing = std.testing;

const engine = @import("engine");
const Game = engine.Game;
const SpriteData = engine.SpriteData;

fn emptyLoader(_: *Game) anyerror!void {}

/// Register an atlas `bundle` into `atlas_manager` carrying `sprites`, and
/// register the matching `AssetCatalog` resource forced to `.ready` so the
/// scene-load gate proceeds without running the real decode worker.
fn installAtlas(game: *Game, bundle: []const u8, sprites: []const []const u8) !void {
    const atlas = try game.atlas_manager.addAtlas(bundle);
    for (sprites) |s| {
        try atlas.addSprite(s, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    }
    try game.assets.register(bundle, .image, "png", "stub-bytes");
    const e = game.assets.entries.getPtr(bundle).?;
    e.state = .ready;
    e.refcount = 0;
}

// ── Module core: reverse index + source walker ───────────────────────

test "inferAssetsFromSource: Sprite ref resolves to its atlas bundle" {
    var index = engine.ReverseIndex.init(testing.allocator);
    defer index.deinit();
    try index.addAtlas("chars", &.{ "hero/idle", "hero/run" });
    try index.addAtlas("ui", &.{"ui/button"});

    const source =
        \\{
        \\  "meta": { "name": "world" },
        \\  "root": {
        \\    "components": { "Sprite": { "sprite_name": "hero/idle" } }
        \\  }
        \\}
    ;

    var manifest = try engine.inferAssetsFromSource(testing.allocator, &index, source);
    defer manifest.deinit();

    // Only the atlas that actually provides the referenced sprite is inferred.
    try testing.expectEqual(@as(usize, 1), manifest.slice().len);
    try testing.expect(manifest.contains("chars"));
    try testing.expect(!manifest.contains("ui"));
}

// ── End-to-end: setScene over a manifest-less, source-bearing scene ──

test "setScene: scene with NO manifest loads inferred asset set" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    try installAtlas(&game, "chars", &.{"hero/idle"});

    // No manifest — only a source referencing the sprite.
    game.registerSceneSimple("world", emptyLoader);
    try game.setSceneSource("world",
        \\{ "root": { "components": { "Sprite": { "sprite_name": "hero/idle" } } } }
    );

    try game.setScene("world");

    // Inference derived + cached the manifest onto the SceneEntry.
    const entry = game.scenes.get("world").?;
    try testing.expectEqual(@as(usize, 1), entry.assets.len);
    try testing.expectEqualStrings("chars", entry.assets[0]);

    // The inferred atlas was actually acquired through the gate.
    try testing.expect(game.assets.entries.getPtr("chars").?.refcount >= 1);

    // The scene committed (it is the current scene).
    try testing.expectEqualStrings("world", game.getCurrentSceneName().?);

    // Exactly one manifest parked; the reverse index was built once.
    try testing.expectEqual(@as(usize, 1), game.inferred_manifests.items.len);
    try testing.expect(game.reverse_index != null);
}

test "setScene: explicit manifest is unchanged — inference never runs" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    // `chars` is what inference WOULD pick if it ran; `explicit` is the
    // hand-declared manifest. They differ so we can tell which path won.
    try installAtlas(&game, "chars", &.{"hero/idle"});
    try game.assets.register("explicit", .image, "png", "stub-bytes");
    const ex = game.assets.entries.getPtr("explicit").?;
    ex.state = .ready;
    ex.refcount = 0;

    const manifest: []const []const u8 = &.{"explicit"};
    game.registerSceneWithAssets("world", emptyLoader, manifest);
    // A source is present too — inference must still be skipped because a
    // manifest is already declared.
    try game.setSceneSource("world",
        \\{ "root": { "components": { "Sprite": { "sprite_name": "hero/idle" } } } }
    );

    try game.setScene("world");

    // The explicit manifest is exactly preserved (same pointer, same content).
    const entry = game.scenes.get("world").?;
    try testing.expectEqual(manifest.ptr, entry.assets.ptr);
    try testing.expectEqual(@as(usize, 1), entry.assets.len);
    try testing.expectEqualStrings("explicit", entry.assets[0]);

    // Inference produced nothing — no manifest parked, index never built.
    try testing.expectEqual(@as(usize, 0), game.inferred_manifests.items.len);
    try testing.expect(game.reverse_index == null);

    // The explicit asset was acquired; the would-be inferred one was NOT.
    try testing.expect(game.assets.entries.getPtr("explicit").?.refcount >= 1);
    try testing.expectEqual(@as(u32, 0), game.assets.entries.getPtr("chars").?.refcount);
}

test "inference is one-shot: re-entering the scene reuses the cached manifest" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    try installAtlas(&game, "chars", &.{"hero/idle"});
    game.registerSceneSimple("world", emptyLoader);
    game.registerSceneSimple("menu", emptyLoader);
    try game.setSceneSource("world",
        \\{ "root": { "components": { "Sprite": { "sprite_name": "hero/idle" } } } }
    );

    try game.setScene("world"); // infers → parks 1
    try game.setScene("menu"); // releases world's inferred manifest
    try game.setScene("world"); // entry.assets already cached → no re-infer

    try testing.expectEqual(@as(usize, 1), game.inferred_manifests.items.len);
}

test "setSceneSource: unknown scene returns SceneNotFound" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    try testing.expectError(error.SceneNotFound, game.setSceneSource("nope", "{}"));
}
