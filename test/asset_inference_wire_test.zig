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

// ── End-to-end: transitive prefab-walk through the live PrefabCache (#754) ──

test "setScene: pure prefab-composition scene infers via the PrefabCache (#754)" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    // Two atlases, each provided by a different prefab.
    try installAtlas(&game, "rooms", &.{"room/floor"});
    try installAtlas(&game, "chars", &.{"worker/idle"});

    // Register the prefabs into the real PrefabCache the resolver reads
    // (`reloadPrefabSource` is the same cache-install seam the assembler's
    // `addEmbeddedPrefab` uses; here it stands in without the full bridge).
    // Each prefab carries an inline Sprite from its atlas; the second is
    // reached transitively (condenser → worker).
    try game.reloadPrefabSource("worker",
        \\{ "Sprite": { "sprite_name": "worker/idle", "pivot": "center" } }
    );
    try game.reloadPrefabSource("condenser",
        \\{ "children": [
        \\  { "Sprite": { "sprite_name": "room/floor", "pivot": "center" } },
        \\  { "prefab": "worker", "Position": { "x": 10, "y": 10 } }
        \\] }
    );

    // A manifest-less scene that is ONLY prefab references (FP `colony` shape):
    // a top-level array of `{ "prefab": ... }` with zero inline Sprite.
    // Pre-#754 this inferred an EMPTY manifest.
    game.registerSceneSimple("colony", emptyLoader);
    try game.setSceneSource("colony",
        \\[ { "prefab": "condenser", "Position": { "x": 0, "y": 0 } } ]
    );

    try game.setScene("colony");

    // The scene now derives a NON-empty manifest: both atlases, unioned from
    // the referenced prefab and its transitively-referenced child prefab.
    const entry = game.scenes.get("colony").?;
    try testing.expectEqual(@as(usize, 2), entry.assets.len);
    var saw_rooms = false;
    var saw_chars = false;
    for (entry.assets) |a| {
        if (std.mem.eql(u8, a, "rooms")) saw_rooms = true;
        if (std.mem.eql(u8, a, "chars")) saw_chars = true;
    }
    try testing.expect(saw_rooms);
    try testing.expect(saw_chars);

    // Both inferred atlases were acquired through the gate, and the scene
    // committed.
    try testing.expect(game.assets.entries.getPtr("rooms").?.refcount >= 1);
    try testing.expect(game.assets.entries.getPtr("chars").?.refcount >= 1);
    try testing.expectEqualStrings("colony", game.getCurrentSceneName().?);
}
