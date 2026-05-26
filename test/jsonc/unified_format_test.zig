//! Loader acceptance tests for the unified scene/prefab format
//! (RFC #560, ticket #561).
//!
//! Pins that the loader walks both shapes down the same code path:
//!
//!  - the unified `"root"` wrapper at the file top,
//!  - `"overrides"` (not `"components"`) on a prefab reference,
//!  - and the legacy spellings — top-level `"entities"`,
//!    `"components"` on a reference, a dropped `"assets"` field —
//!    still load during the migration window.
//!
//! Cross-compatibility matters most: a unified scene referencing a
//! legacy prefab (and vice-versa) must resolve, since files migrate
//! one at a time.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const core = @import("labelle-core");

// Two trivial components so a test can assert both "the override
// won" and "the un-mentioned prefab component survived."
const Marker = struct {
    pub const save = core.Saveable(.saveable, @This(), .{});
    id: i32 = 0,
};

const Health = struct {
    pub const save = core.Saveable(.saveable, @This(), .{});
    current: f32 = 0,
};

const TestComponents = engine.ComponentRegistry(.{
    .Marker = Marker,
    .Health = Health,
});

const MockEcs = core.MockEcsBackend(u32);
const TestGame = engine.game_mod.GameConfig(
    core.StubRender(MockEcs.Entity),
    MockEcs,
    engine.input_mod.StubInput,
    engine.audio_mod.StubAudio,
    engine.gui_mod.StubGui,
    void,
    core.StubLogSink,
    TestComponents,
    &.{},
    void,
);

const Bridge = engine.JsoncSceneBridge(TestGame, TestComponents);

// A path with no `prefabs/` directory, so the prefab cache never
// finds a filesystem fallback — every prefab in these tests must
// come from `addEmbeddedPrefab`.
const PREFAB_DIR = "/tmp/labelle-nonexistent-561";

fn boot(scene_jsonc: []const u8) !TestGame {
    var game = TestGame.init(testing.allocator);
    errdefer game.deinit();
    try Bridge.loadSceneFromSource(&game, scene_jsonc, PREFAB_DIR);
    return game;
}

/// Sorted `Marker.id` values of every entity carrying a `Marker`.
fn markerIds(game: *TestGame, buf: []i32) []i32 {
    var view = game.ecs_backend.view(.{Marker}, .{});
    defer view.deinit();
    var n: usize = 0;
    while (view.next()) |e| : (n += 1) {
        buf[n] = game.ecs_backend.getComponent(e, Marker).?.id;
    }
    const ids = buf[0..n];
    std.mem.sort(i32, ids, {}, std.sort.asc(i32));
    return ids;
}

/// The single entity carrying a `Marker` (fails if not exactly one).
fn soleMarker(game: *TestGame) Marker {
    var view = game.ecs_backend.view(.{Marker}, .{});
    defer view.deinit();
    const e = view.next().?;
    std.debug.assert(view.next() == null);
    return game.ecs_backend.getComponent(e, Marker).?.*;
}

// ── Unified "root" wrapper ──────────────────────────────────────

test "unified: root wrapper, children load as entities" {
    var game = try boot(
        \\{ "root": { "children": [
        \\  { "components": { "Marker": { "id": 1 } } },
        \\  { "components": { "Marker": { "id": 2 } } }
        \\] } }
    );
    defer game.deinit();

    var buf: [8]i32 = undefined;
    try testing.expectEqualSlices(i32, &.{ 1, 2 }, markerIds(&game, &buf));
}

test "unified: nested children under the root wrapper load" {
    var game = try boot(
        \\{ "root": { "children": [
        \\  { "components": { "Marker": { "id": 1 } },
        \\    "children": [ { "components": { "Marker": { "id": 2 } } } ] }
        \\] } }
    );
    defer game.deinit();

    var buf: [8]i32 = undefined;
    try testing.expectEqualSlices(i32, &.{ 1, 2 }, markerIds(&game, &buf));
}

// ── Legacy shapes still accepted ────────────────────────────────

test "legacy: top-level entities array still loads" {
    var game = try boot(
        \\{ "entities": [ { "components": { "Marker": { "id": 9 } } } ] }
    );
    defer game.deinit();

    try testing.expectEqual(@as(i32, 9), soleMarker(&game).id);
}

test "legacy: dropped assets field is ignored, scene still loads" {
    var game = try boot(
        \\{ "assets": ["rooms", "props"],
        \\  "entities": [ { "components": { "Marker": { "id": 8 } } } ] }
    );
    defer game.deinit();

    try testing.expectEqual(@as(i32, 8), soleMarker(&game).id);
}

// ── Prefab references: overrides vs. legacy components ──────────

test "unified: reference with overrides patches a unified prefab" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try Bridge.addEmbeddedPrefab(&game, "widget",
        \\{ "root": { "components": { "Marker": { "id": 100 } } } }
    , PREFAB_DIR);
    try Bridge.loadSceneFromSource(&game,
        \\{ "root": { "children": [
        \\  { "prefab": "widget", "overrides": { "Marker": { "id": 7 } } }
        \\] } }
    , PREFAB_DIR);

    try testing.expectEqual(@as(i32, 7), soleMarker(&game).id);
}

test "legacy: reference with components still patches a legacy prefab" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try Bridge.addEmbeddedPrefab(&game, "legacy_widget",
        \\{ "components": { "Marker": { "id": 200 } } }
    , PREFAB_DIR);
    try Bridge.loadSceneFromSource(&game,
        \\{ "entities": [
        \\  { "prefab": "legacy_widget", "components": { "Marker": { "id": 5 } } }
        \\] }
    , PREFAB_DIR);

    try testing.expectEqual(@as(i32, 5), soleMarker(&game).id);
}

// ── Cross-compatibility (files migrate one at a time) ───────────

test "cross: unified scene + overrides references a legacy prefab" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try Bridge.addEmbeddedPrefab(&game, "legacy_prefab",
        \\{ "components": { "Marker": { "id": 300 } } }
    , PREFAB_DIR);
    try Bridge.loadSceneFromSource(&game,
        \\{ "root": { "children": [
        \\  { "prefab": "legacy_prefab", "overrides": { "Marker": { "id": 11 } } }
        \\] } }
    , PREFAB_DIR);

    try testing.expectEqual(@as(i32, 11), soleMarker(&game).id);
}

test "cross: legacy scene + components references a unified prefab" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try Bridge.addEmbeddedPrefab(&game, "unified_prefab",
        \\{ "root": { "components": { "Marker": { "id": 400 } } } }
    , PREFAB_DIR);
    try Bridge.loadSceneFromSource(&game,
        \\{ "entities": [
        \\  { "prefab": "unified_prefab", "components": { "Marker": { "id": 13 } } }
        \\] }
    , PREFAB_DIR);

    try testing.expectEqual(@as(i32, 13), soleMarker(&game).id);
}

// ── Merge behavior (unchanged by the rename — RFC #562 formalizes) ──

test "overrides leave un-mentioned prefab components intact" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try Bridge.addEmbeddedPrefab(&game, "two_comp",
        \\{ "root": { "components": {
        \\  "Marker": { "id": 50 },
        \\  "Health": { "current": 80 }
        \\} } }
    , PREFAB_DIR);
    try Bridge.loadSceneFromSource(&game,
        \\{ "root": { "children": [
        \\  { "prefab": "two_comp", "overrides": { "Marker": { "id": 3 } } }
        \\] } }
    , PREFAB_DIR);

    var view = game.ecs_backend.view(.{ Marker, Health }, .{});
    defer view.deinit();
    const e = view.next().?;
    try testing.expectEqual(@as(i32, 3), game.ecs_backend.getComponent(e, Marker).?.id);
    try testing.expectEqual(@as(f32, 80), game.ecs_backend.getComponent(e, Health).?.current);
}

// ── Registry: effective name + collision detection (RFC #561) ───

test "registry: prefab resolves by its name field, not the file basename" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    // Embedded as basename "widget_file", but the file declares
    // its own registry name — references must use that name.
    try Bridge.addEmbeddedPrefab(&game, "widget_file",
        \\{ "name": "fancy_widget",
        \\  "root": { "components": { "Marker": { "id": 42 } } } }
    , PREFAB_DIR);
    try Bridge.loadSceneFromSource(&game,
        \\{ "root": { "children": [ { "prefab": "fancy_widget" } ] } }
    , PREFAB_DIR);

    try testing.expectEqual(@as(i32, 42), soleMarker(&game).id);
}

test "registry: duplicate name field is a load-time error" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try Bridge.addEmbeddedPrefab(&game, "first_file",
        \\{ "name": "shared", "root": { "components": { "Marker": { "id": 1 } } } }
    , PREFAB_DIR);
    try testing.expectError(error.DuplicatePrefabName, Bridge.addEmbeddedPrefab(&game, "second_file",
        \\{ "name": "shared", "root": { "components": { "Marker": { "id": 2 } } } }
    , PREFAB_DIR));
}

// ── §B2 rejection: {prefab + children} at a reference site ─────────
//
// RFC #560 §B2: a reference entry (`prefab` set) cannot also
// declare `children`. Inline mode authors; reference mode
// instantiates — appending children at a use site would silently
// re-author the recipe. The assembler rejects this shape pre-parse
// (labelle-assembler#182); the engine loader enforces the same rule
// at load time (#586) as defense-in-depth for content that bypassed
// the assembler — embedded sources in tests, hand-edited save
// files, third-party tools.

test "unified: prefab reference with children is a load-time error" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    try Bridge.addEmbeddedPrefab(&game, "door",
        \\{ "root": { "components": { "Marker": { "id": 1 } } } }
    , PREFAB_DIR);
    const src =
        \\{ "root": { "children": [
        \\  { "prefab": "door",
        \\    "overrides": { "Marker": { "id": 2 } },
        \\    "children": [ { "components": { "Marker": { "id": 3 } } } ] }
        \\] } }
    ;
    try testing.expectError(error.InvalidFormat, Bridge.loadSceneFromSource(&game, src, PREFAB_DIR));
}

test "unified: prefab root with children is a load-time error" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    try Bridge.addEmbeddedPrefab(&game, "door",
        \\{ "root": { "components": { "Marker": { "id": 1 } } } }
    , PREFAB_DIR);
    const src =
        \\{ "root": {
        \\  "prefab": "door",
        \\  "children": [ { "components": { "Marker": { "id": 3 } } } ]
        \\} }
    ;
    try testing.expectError(error.InvalidFormat, Bridge.loadSceneFromSource(&game, src, PREFAB_DIR));
}

// Defense-in-depth for content the file-root gate can't see: a
// prefab parsed through `addEmbeddedPrefab` (or any third-party
// source that lands in the prefab cache without traversing
// `loadSceneFile`/`loadSceneSource`) whose own root is itself a
// reference-mode `{prefab + children}` block. The scene-side
// reference looks innocent, but the resolved prefab root is the
// §B2 violation. The loader re-validates at every prefab
// resolution site, so the scene-load fails even though the
// scene file is well-formed.
test "unified: resolved prefab root with {prefab + children} is a load-time error" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    try Bridge.addEmbeddedPrefab(&game, "base",
        \\{ "root": { "components": { "Marker": { "id": 1 } } } }
    , PREFAB_DIR);
    // `door` is itself reference-mode AND declares children — this
    // is the shape the file-root gate would normally catch when the
    // prefab is loaded as a scene, but `addEmbeddedPrefab` doesn't
    // gate. The violation must surface at use-site instead.
    try Bridge.addEmbeddedPrefab(&game, "door",
        \\{ "root": {
        \\  "prefab": "base",
        \\  "children": [ { "components": { "Marker": { "id": 2 } } } ]
        \\} }
    , PREFAB_DIR);
    const src =
        \\{ "root": { "children": [ { "prefab": "door" } ] } }
    ;
    try testing.expectError(error.InvalidFormat, Bridge.loadSceneFromSource(&game, src, PREFAB_DIR));
}

// Defense-in-depth for entity-like objects smuggled into a
// component array: the visit-time §B2 gate in `loadEntityInternal`
// only fires when the walker traverses the `children` path, but
// component-nested entities (e.g. a workstation's storages,
// a room's furniture array) are spawned by
// `spawnAndLinkNestedEntities` — a separate walk that also has
// to reject `{prefab + children}` or the violation loads silently.
test "unified: {prefab + children} in a component-nested entity array is a load-time error" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    try Bridge.addEmbeddedPrefab(&game, "item",
        \\{ "root": { "components": { "Marker": { "id": 1 } } } }
    , PREFAB_DIR);
    // The outer entity inlines a component whose value is an array
    // of entity-like objects. One of them is reference-mode AND
    // declares children — the §B2 violation we want to catch.
    const src =
        \\{ "root": { "children": [
        \\  { "components": {
        \\      "Marker": { "id": 0 },
        \\      "Container": { "items": [
        \\        { "prefab": "item",
        \\          "children": [ { "components": { "Marker": { "id": 99 } } } ] }
        \\      ] }
        \\  } }
        \\] } }
    ;
    try testing.expectError(error.InvalidFormat, Bridge.loadSceneFromSource(&game, src, PREFAB_DIR));
}

test "registry: a name field colliding with another file's basename errors" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    // First file has no "name" — effective name is its basename "alpha".
    try Bridge.addEmbeddedPrefab(&game, "alpha",
        \\{ "root": { "components": { "Marker": { "id": 1 } } } }
    , PREFAB_DIR);
    // Second file's "name" collides with that basename.
    try testing.expectError(error.DuplicatePrefabName, Bridge.addEmbeddedPrefab(&game, "beta",
        \\{ "name": "alpha", "root": { "components": { "Marker": { "id": 2 } } } }
    , PREFAB_DIR));
}
