//! Runtime scene-source override map (labelle-studio Play mode /
//! `editor_api.editor_load_scene`).
//!
//! Covers the two loader seams that consult `game.scene_source_overrides`:
//!   - `loadSceneFromSource` (the assembler-generated per-scene loader)
//!     resolves the override by the NAME of the scene being loaded
//!     (`game.loading_scene_name`, set around `setScene`'s loader call);
//!   - `loadSceneFile` (include fragments) resolves by exact path, then
//!     by the path's stem (`"scenes/frag.jsonc"` → `"frag"`).
//! Plus ownership: replacing an entry frees the previous copy (verified
//! by std.testing.allocator's leak/double-free detection).

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");

const Game = engine.Game;
const editor_api = engine.editor_api;

const Marker = struct { _: u8 = 1 };

const Components = engine.ComponentRegistry(.{
    .Marker = Marker,
});

const Bridge = engine.JsoncSceneBridge(Game, Components);

// One entity in the compiled-in ("embedded") source…
const base_src =
    \\{ "entities": [
    \\  { "components": { "Position": { "x": 1, "y": 1 } } }
    \\] }
;

// …two in the editor's override.
const override_src =
    \\{ "entities": [
    \\  { "components": { "Position": { "x": 10, "y": 10 } } },
    \\  { "components": { "Position": { "x": 20, "y": 20 } } }
    \\] }
;

// Three in a second override, to prove replacement takes effect (and
// frees the first copy).
const override2_src =
    \\{ "entities": [
    \\  { "components": { "Position": { "x": 1, "y": 0 } } },
    \\  { "components": { "Position": { "x": 2, "y": 0 } } },
    \\  { "components": { "Position": { "x": 3, "y": 0 } } }
    \\] }
;

/// Mirrors the assembler-generated per-scene loader shape:
/// `JsoncBridge.loadSceneFromSource(game, @embedFile(...), "prefabs")`.
fn mainLoader(game: *Game) anyerror!void {
    return Bridge.loadSceneFromSource(game, base_src, "prefabs");
}

test "loadSceneFromSource: override by scene name replaces the embedded source" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    game.registerSceneSimple("main", mainLoader);

    // Without an override the embedded source loads.
    try game.setScene("main");
    try testing.expectEqual(@as(usize, 1), game.entityCount());

    // Store an override for "main" and reload: the override wins.
    try game.setSceneSourceOverride("main", override_src);
    try game.setScene("main");
    try testing.expectEqual(@as(usize, 2), game.entityCount());
}

test "setSceneSourceOverride: replacing an entry frees the old copy and takes effect" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    game.registerSceneSimple("main", mainLoader);

    try game.setSceneSourceOverride("main", override_src);
    try game.setSceneSourceOverride("main", override2_src);

    // The second override is what loads…
    try game.setScene("main");
    try testing.expectEqual(@as(usize, 3), game.entityCount());

    // …and the stored copy is the map's own memory, not the caller's.
    const stored = game.sceneSourceOverride("main").?;
    try testing.expect(stored.ptr != @as([]const u8, override2_src).ptr);
    try testing.expectEqualStrings(override2_src, stored);
    // (testing.allocator's leak check on deinit proves the replaced
    // first copy was freed exactly once.)
}

test "sceneSourceOverride: exact key first, then path stem; no false positives" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    try testing.expect(game.sceneSourceOverride("main") == null);

    try game.setSceneSourceOverride("frag", "override-bytes");
    // Scene-name lookup (loadSceneFromSource path).
    try testing.expectEqualStrings("override-bytes", game.sceneSourceOverride("frag").?);
    // Include-path lookup falls back to the stem (loadSceneFile path).
    try testing.expectEqualStrings("override-bytes", game.sceneSourceOverride("scenes/frag.jsonc").?);
    // Different stem: miss.
    try testing.expect(game.sceneSourceOverride("scenes/other.jsonc") == null);

    // Exact path keys outrank the stem fallback.
    try game.setSceneSourceOverride("scenes/frag.jsonc", "exact-bytes");
    try testing.expectEqualStrings("exact-bytes", game.sceneSourceOverride("scenes/frag.jsonc").?);
    try testing.expectEqualStrings("override-bytes", game.sceneSourceOverride("frag").?);
}

// Root scene that pulls in an include fragment — the fragment arrives
// via `addEmbeddedSceneSource` exactly like the assembler emits it.
const root_with_include_src =
    \\{
    \\  "include": ["scenes/frag.jsonc"],
    \\  "entities": [
    \\    { "components": { "Position": { "x": 0, "y": 0 } } }
    \\  ]
    \\}
;

const frag_src =
    \\{ "entities": [
    \\  { "components": { "Position": { "x": 5, "y": 5 } } }
    \\] }
;

const frag_override_src =
    \\{ "entities": [
    \\  { "components": { "Position": { "x": 6, "y": 6 } } },
    \\  { "components": { "Position": { "x": 7, "y": 7 } } }
    \\] }
;

fn includeLoader(game: *Game) anyerror!void {
    return Bridge.loadSceneFromSource(game, root_with_include_src, "prefabs");
}

test "loadSceneFile: include fragments consult the override map by stem" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    game.registerSceneSimple("world", includeLoader);
    try game.addEmbeddedSceneSource("scenes/frag.jsonc", frag_src);

    // Embedded fragment: 1 root entity + 1 fragment entity.
    try game.setScene("world");
    try testing.expectEqual(@as(usize, 2), game.entityCount());

    // Override the fragment by its scene name ("frag"): the include
    // path "scenes/frag.jsonc" resolves it via the stem fallback.
    try game.setSceneSourceOverride("frag", frag_override_src);
    try game.setScene("world");
    try testing.expectEqual(@as(usize, 3), game.entityCount());
}

test "editor_load_scene: stores the override and reloads the current scene now" {
    editor_api.unbind();
    defer editor_api.unbind();

    var game = Game.init(testing.allocator);
    defer game.deinit();
    game.registerSceneSimple("main", mainLoader);
    try game.setScene("main");
    try testing.expectEqual(@as(usize, 1), game.entityCount());

    var runner: u32 = 0;
    editor_api.bind(&game, &runner);

    // Overriding a NON-current scene stores without reloading.
    try testing.expectEqual(
        @as(i32, 0),
        editor_api.editor_load_scene("other", 5, override_src, override_src.len),
    );
    try testing.expectEqual(@as(usize, 1), game.entityCount());
    try testing.expect(game.sceneSourceOverride("other") != null);

    // Overriding the CURRENT scene reloads immediately.
    try testing.expectEqual(
        @as(i32, 0),
        editor_api.editor_load_scene("main", 4, override_src, override_src.len),
    );
    try testing.expectEqualStrings("main", game.getCurrentSceneName().?);
    try testing.expectEqual(@as(usize, 2), game.entityCount());
}
