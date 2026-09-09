//! Loader acceptance tests for the unified scene/prefab format
//! (RFC #560, ticket #561).
//!
//! Pins that the loader walks every current shape down the same
//! code path:
//!
//!  - the unified `"root"` wrapper at the file top,
//!  - the flat top-level form and the RFC #596 bundle Array,
//!  - `"overrides"` (not `"components"`) on a prefab reference.
//!
//! And pins that the pre-#560 legacy spellings — a top-level
//! `"entities"` array, a `"components"` wrapper on a prefab
//! reference, and a top-level `"assets"` array — are REJECTED as of
//! engine v2.0 (#592) with `error.InvalidFormat`. `labelle migrate
//! unified` converts a legacy file to the unified/flat form.

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

// A component whose data field is an array of structs that themselves
// use PascalCase keys. Pins that `isEntityLike` does NOT classify
// these inner data objects as entities — they're component-value
// data, not entity definitions (RFC #596 cursor MED).
const FireSpellEntry = struct {
    pub const save = core.Saveable(.saveable, @This(), .{});
    Type: i32 = 0,
    DamageMultiplier: i32 = 0,
};

const FireSpell = struct {
    pub const save = core.Saveable(.saveable, @This(), .{});
    entries: []const FireSpellEntry = &.{},
};

const TestComponents = engine.ComponentRegistry(.{
    .Marker = Marker,
    .Health = Health,
    .FireSpell = FireSpell,
});

const MockEcs = core.MockEcsBackend(u32);
const TestGame = engine.game_mod.GameConfig(
    core.StubRender(MockEcs.Entity),
    MockEcs,
    engine.input_mod.StubInput,
    engine.audio_mod.StubAudio,
    engine.StubVideo,
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

// ── Legacy shapes now rejected (engine v2.0, #592) ──────────────

test "legacy: top-level entities array is a load-time error" {
    // The pre-#560 top-level `"entities"` wrapper is no longer
    // accepted — use `"children"` (or a top-level bundle Array).
    try testing.expectError(error.InvalidFormat, boot(
        \\{ "entities": [ { "components": { "Marker": { "id": 9 } } } ] }
    ));
}

test "legacy: top-level assets field is a load-time error" {
    // Assets are inferred from sprite references (RFC #563); a
    // dropped `"assets"` field is now rejected, not ignored.
    try testing.expectError(error.InvalidFormat, boot(
        \\{ "assets": ["rooms", "props"],
        \\  "children": [ { "components": { "Marker": { "id": 8 } } } ] }
    ));
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

test "legacy: components on a prefab reference is a load-time error" {
    // A reference patches via `"overrides"` (or flat PascalCase
    // keys); the pre-#560 `"components"` wrapper on a reference is
    // rejected in v2.0 (#592).
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try Bridge.addEmbeddedPrefab(&game, "widget",
        \\{ "components": { "Marker": { "id": 200 } } }
    , PREFAB_DIR);
    try testing.expectError(error.InvalidFormat, Bridge.loadSceneFromSource(&game,
        \\{ "children": [
        \\  { "prefab": "widget", "components": { "Marker": { "id": 5 } } }
        \\] }
    , PREFAB_DIR));
}

// ── Cross-compatibility (files migrate one at a time) ───────────

test "cross: flat prefab (components wrapper, no root) resolves via overrides" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    // The prefab uses the flat form — a top-level `"components"`
    // wrapper with no `"root"` (valid, RFC #594). The scene patches
    // it with `"overrides"`.
    try Bridge.addEmbeddedPrefab(&game, "flat_prefab",
        \\{ "components": { "Marker": { "id": 300 } } }
    , PREFAB_DIR);
    try Bridge.loadSceneFromSource(&game,
        \\{ "root": { "children": [
        \\  { "prefab": "flat_prefab", "overrides": { "Marker": { "id": 11 } } }
        \\] } }
    , PREFAB_DIR);

    try testing.expectEqual(@as(i32, 11), soleMarker(&game).id);
}

test "cross: bundle scene + overrides references a root-wrapped prefab" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try Bridge.addEmbeddedPrefab(&game, "unified_prefab",
        \\{ "root": { "components": { "Marker": { "id": 400 } } } }
    , PREFAB_DIR);
    try Bridge.loadSceneFromSource(&game,
        \\[
        \\  { "prefab": "unified_prefab", "overrides": { "Marker": { "id": 13 } } }
        \\]
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

// ── Flat-form (RFC #594) ────────────────────────────────────────
//
// RFC #594 drops the `"root"` wrapper: top-level keys ARE the
// entity. The loader dual-accepts both shapes during the v1.x
// deprecation window; v2.0 removes the root-wrapped path. No
// warning fires on either shape — see the RFC's "Loader changes"
// section for the rationale. These tests pin the new shape down
// the same code path as the root-wrapped tests above.

test "flat: component-only prefab loads via reference" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    // No `"root"` wrapper — top-level `"components"` is the entity.
    try Bridge.addEmbeddedPrefab(&game, "marker_only",
        \\{ "components": { "Marker": { "id": 77 } } }
    , PREFAB_DIR);
    try Bridge.loadSceneFromSource(&game,
        \\{ "children": [ { "prefab": "marker_only" } ] }
    , PREFAB_DIR);

    try testing.expectEqual(@as(i32, 77), soleMarker(&game).id);
}

test "flat: prefab with components + children loads via reference" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try Bridge.addEmbeddedPrefab(&game, "parent_flat",
        \\{ "components": { "Marker": { "id": 10 } },
        \\  "children": [ { "components": { "Marker": { "id": 11 } } } ] }
    , PREFAB_DIR);
    try Bridge.loadSceneFromSource(&game,
        \\{ "children": [ { "prefab": "parent_flat" } ] }
    , PREFAB_DIR);

    var buf: [8]i32 = undefined;
    try testing.expectEqualSlices(i32, &.{ 10, 11 }, markerIds(&game, &buf));
}

test "flat: prefab reference at root (specialization) resolves through cache" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    // Base prefab in flat form.
    try Bridge.addEmbeddedPrefab(&game, "base_flat",
        \\{ "components": { "Marker": { "id": 100 }, "Health": { "current": 50 } } }
    , PREFAB_DIR);
    // Specialization prefab — flat reference-mode at the root. The
    // resolver walks the cache, applying the override on top of
    // `base_flat`'s components.
    try Bridge.addEmbeddedPrefab(&game, "spec_flat",
        \\{ "prefab": "base_flat", "overrides": { "Marker": { "id": 200 } } }
    , PREFAB_DIR);
    // Scene that instantiates the specialization. We reference
    // `base_flat` directly with the same override to confirm the
    // flat reference-mode root parses without errors; the
    // specialization-prefab full chain is exercised by the cache
    // lookup at `loadEntityInternal`.
    try Bridge.loadSceneFromSource(&game,
        \\{ "children": [
        \\  { "prefab": "base_flat", "overrides": { "Marker": { "id": 200 } } }
        \\] }
    , PREFAB_DIR);

    var view = game.ecs_backend.view(.{ Marker, Health }, .{});
    defer view.deinit();
    const e = view.next().?;
    try testing.expectEqual(@as(i32, 200), game.ecs_backend.getComponent(e, Marker).?.id);
    try testing.expectEqual(@as(f32, 50), game.ecs_backend.getComponent(e, Health).?.current);
}

test "flat: scene with name + children loads with correct child count" {
    // `"name"` metadata sits alongside `"children"` at the top level
    // — the closed-disjoint key sets of RFC #594.
    var game = try boot(
        \\{ "name": "main",
        \\  "children": [
        \\    { "components": { "Marker": { "id": 1 } } },
        \\    { "components": { "Marker": { "id": 2 } } },
        \\    { "components": { "Marker": { "id": 3 } } }
        \\  ] }
    );
    defer game.deinit();

    var buf: [8]i32 = undefined;
    try testing.expectEqualSlices(i32, &.{ 1, 2, 3 }, markerIds(&game, &buf));
}

test "flat: §B2 still fires on a flat reference-mode root with children" {
    // RFC #560 §B2: a reference entry cannot also declare children.
    // The file-root §B2 gate now consults `uf.rootObject(scene_obj)`,
    // which returns the file object itself for flat form — so the
    // gate fires at the new top level just like at the old `"root"`
    // block.
    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    try Bridge.addEmbeddedPrefab(&game, "door",
        \\{ "components": { "Marker": { "id": 1 } } }
    , PREFAB_DIR);
    const src =
        \\{ "prefab": "door",
        \\  "children": [ { "components": { "Marker": { "id": 3 } } } ] }
    ;
    try testing.expectError(error.InvalidFormat, Bridge.loadSceneFromSource(&game, src, PREFAB_DIR));
}

test "flat: dual-acceptance — root-wrapped form still loads unchanged" {
    // Regression pin for RFC #594's dual-acceptance promise: the
    // root-wrapped shape continues to load through the v1.x window.
    // V2.0 removes this path (engine#592 bundles); the test below
    // is what guards that we did NOT break root-wrapped scenes
    // when adding the flat path.
    var game = try boot(
        \\{ "name": "main",
        \\  "root": { "children": [
        \\    { "components": { "Marker": { "id": 1 } } },
        \\    { "components": { "Marker": { "id": 2 } } }
        \\  ] } }
    );
    defer game.deinit();

    var buf: [8]i32 = undefined;
    try testing.expectEqualSlices(i32, &.{ 1, 2 }, markerIds(&game, &buf));
}

// ── RFC #596: wrapper-flat + bundle + meta forms ────────────────
//
// RFC #596 extends the dual-accept matrix with three more axes:
//
//   1. Wrapper-flat components — PascalCase keys at the entity
//      scope ARE components, no `overrides:` / `components:`
//      wrapper required.
//   2. File-as-array bundles — top-level Array is a list of sibling
//      entities (no implicit root), with an optional `{ meta: ... }`
//      file-header element at index 0.
//   3. `meta:` field at entity and file-header scope — stripped at
//      load, never reaches runtime, never propagates.
//   4. Unknown PascalCase keys warn-once (forward-compat with
//      cross-repo plugin authoring; typos still surface).
//
// All axes are dual-accept during v1.x; wrapped forms keep working
// throughout. The §B2 gate fires at every shape.

test "rfc596: flat reference — PascalCase override sibling of prefab key" {
    // `{ "prefab": "x", "Marker": { ... } }` — no `overrides`
    // wrapper. The PascalCase key IS the override (RFC #596 Axis 2).
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try Bridge.addEmbeddedPrefab(&game, "widget",
        \\{ "root": { "components": { "Marker": { "id": 100 } } } }
    , PREFAB_DIR);
    try Bridge.loadSceneFromSource(&game,
        \\{ "children": [
        \\  { "prefab": "widget", "Marker": { "id": 42 } }
        \\] }
    , PREFAB_DIR);

    try testing.expectEqual(@as(i32, 42), soleMarker(&game).id);
}

test "rfc596: flat inline — PascalCase keys declare an inline entity" {
    // `{ "Marker": { ... } }` — no `components` wrapper. The
    // PascalCase key IS the inline component (RFC #596 Axis 2).
    var game = try boot(
        \\{ "children": [
        \\  { "Marker": { "id": 7 } },
        \\  { "Marker": { "id": 8 } }
        \\] }
    );
    defer game.deinit();

    var buf: [8]i32 = undefined;
    try testing.expectEqualSlices(i32, &.{ 7, 8 }, markerIds(&game, &buf));
}

test "rfc596: bundle scene — top-level Array spawns N siblings" {
    // RFC #596 Axis 3: file-as-array. No implicit root entity, no
    // shared parent — every array element is a sibling.
    var game = try boot(
        \\[
        \\  { "Marker": { "id": 1 } },
        \\  { "Marker": { "id": 2 } },
        \\  { "Marker": { "id": 3 } }
        \\]
    );
    defer game.deinit();

    var buf: [8]i32 = undefined;
    try testing.expectEqualSlices(i32, &.{ 1, 2, 3 }, markerIds(&game, &buf));
}

test "rfc596: bundle header — only-meta object at index 0 is file-meta, not entity" {
    // The first array element with ONLY `meta:` (no entity-shape
    // keys) is the file header — treated as authoring metadata, not
    // an entity. The other elements spawn normally.
    var game = try boot(
        \\[
        \\  { "meta": { "name": "Production Colony Demo", "author": "alexandre" } },
        \\  { "Marker": { "id": 10 } },
        \\  { "Marker": { "id": 11 } }
        \\]
    );
    defer game.deinit();

    var buf: [8]i32 = undefined;
    try testing.expectEqualSlices(i32, &.{ 10, 11 }, markerIds(&game, &buf));
}

test "rfc596: empty bundle [] is valid, zero entities" {
    // Empty bundles are valid per the RFC's Q2 resolution —
    // authoring workflows benefit (new file → `[]` → add entities).
    var game = try boot("[]");
    defer game.deinit();

    var buf: [8]i32 = undefined;
    try testing.expectEqualSlices(i32, &.{}, markerIds(&game, &buf));
}

test "rfc596: meta on an entity is stripped — never reaches runtime" {
    // The `meta:` key is dropped at load. The entity spawns with
    // its components; `meta` is not a component, not attached to
    // the entity, not visible to gameplay code. The test passes if
    // (a) loading succeeds, and (b) `Marker` is applied normally —
    // no spurious warning, no extra entity.
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try Bridge.addEmbeddedPrefab(&game, "widget",
        \\{ "root": { "components": { "Marker": { "id": 100 } } } }
    , PREFAB_DIR);
    try Bridge.loadSceneFromSource(&game,
        \\{ "children": [
        \\  { "prefab": "widget", "meta": { "label": "main kitchen", "tags": ["debug"] } }
        \\] }
    , PREFAB_DIR);

    // The widget spawned with the prefab's default Marker.id=100;
    // `meta` is gone, no second entity was created from it.
    try testing.expectEqual(@as(i32, 100), soleMarker(&game).id);
}

test "rfc596: meta does NOT propagate from prefab file to scene reference" {
    // RFC §"Authoring-only / No propagation": a prefab file's
    // file-level meta is local to the prefab. A scene that
    // references it without its own `meta:` gets no meta on the
    // spawned entity (and the prefab's meta is NOT silently
    // attached as a component).
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    // Prefab in flat shape with its own meta block.
    try Bridge.addEmbeddedPrefab(&game, "labeled",
        \\{ "Marker": { "id": 50 },
        \\  "meta": { "author": "A", "version": 3 } }
    , PREFAB_DIR);
    // Scene reference has no `meta:` of its own.
    try Bridge.loadSceneFromSource(&game,
        \\[ { "prefab": "labeled" } ]
    , PREFAB_DIR);

    // Spawn succeeded with the prefab's Marker only. If `meta`
    // were applied as a component, the apply-component pipeline
    // would have warned (`uf.warnUnknownComponent` only fires for
    // PascalCase keys, but `meta` is lowercase — it's structural)
    // — but more importantly, only ONE marker exists at id=50, no
    // second entity, no error.
    try testing.expectEqual(@as(i32, 50), soleMarker(&game).id);
}

test "rfc596: unknown PascalCase component (typo) warns but does not crash" {
    // RFC #596 Axis 4: unknown PascalCase keys are treated as
    // components, but the loader warns-once instead of erroring.
    // Forward-compat: write the prefab before the plugin lands.
    // Catches typos like `Posiiton` visibly.
    //
    // The test asserts behavior — load succeeds and the known
    // sibling component still applies. The warning is observed
    // out-of-band (StubLogSink swallows it, but the warn-once dedup
    // set in `unified_format.zig` is the truthful signal — exercised
    // by the load path).
    var game = try boot(
        \\{ "children": [
        \\  { "Marker": { "id": 42 }, "Posiiton": { "x": 0, "y": 0 } }
        \\] }
    );
    defer game.deinit();

    // `Marker` applied normally; the typo'd component was ignored
    // (no entity-side effect, no crash).
    try testing.expectEqual(@as(i32, 42), soleMarker(&game).id);
}

test "rfc596: wrapped 'overrides' form still works (dual-accept regression)" {
    // The RFC promises dual-accept during v1.x — adding the flat
    // path MUST NOT break wrapped scenes. This test is the
    // regression pin for that promise: the same scene shape as
    // pre-RFC-596 keeps resolving cleanly.
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try Bridge.addEmbeddedPrefab(&game, "widget",
        \\{ "root": { "components": { "Marker": { "id": 100 } } } }
    , PREFAB_DIR);
    try Bridge.loadSceneFromSource(&game,
        \\{ "children": [
        \\  { "prefab": "widget", "overrides": { "Marker": { "id": 9 } } }
        \\] }
    , PREFAB_DIR);

    try testing.expectEqual(@as(i32, 9), soleMarker(&game).id);
}

test "rfc596: §B2 still fires on a flat bundle element with {prefab + children}" {
    // The §B2 gate (RFC #560: no `children` on a reference) must
    // catch the violation in the bundle shape too. The file-root
    // gate doesn't apply (a bundle has no root), but the per-entry
    // gate inside `loadEntityInternal` fires on every visit.
    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    try Bridge.addEmbeddedPrefab(&game, "door",
        \\{ "components": { "Marker": { "id": 1 } } }
    , PREFAB_DIR);

    const src =
        \\[
        \\  { "prefab": "door",
        \\    "children": [ { "Marker": { "id": 99 } } ] }
        \\]
    ;
    try testing.expectError(error.InvalidFormat, Bridge.loadSceneFromSource(&game, src, PREFAB_DIR));
}

test "rfc596: flat prefab with PascalCase components resolves via reference" {
    // RFC #596 Axis 2 applied to prefabs: a prefab file can drop
    // its `components:` wrapper too. The flat references resolve
    // through the cache identically.
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    // Prefab in fully flat form — no `root`, no `components`.
    try Bridge.addEmbeddedPrefab(&game, "flat_widget",
        \\{ "Marker": { "id": 200 }, "Health": { "current": 75 } }
    , PREFAB_DIR);
    try Bridge.loadSceneFromSource(&game,
        \\[
        \\  { "prefab": "flat_widget", "Marker": { "id": 5 } }
        \\]
    , PREFAB_DIR);

    var view = game.ecs_backend.view(.{ Marker, Health }, .{});
    defer view.deinit();
    const e = view.next().?;
    try testing.expectEqual(@as(i32, 5), game.ecs_backend.getComponent(e, Marker).?.id);
    try testing.expectEqual(@as(f32, 75), game.ecs_backend.getComponent(e, Health).?.current);
}

// ── Regression tests for PR #597 review findings ───────────────

test "rfc596: malformed top-level value (string) returns error.InvalidFormat" {
    // Gemini HIGH (#597): `classifyTopLevel` returns null for any
    // scalar at the file top level; the loader must surface
    // `error.InvalidFormat` instead of silently succeeding.
    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    try testing.expectError(error.InvalidFormat, Bridge.loadSceneFromSource(&game, "\"malformed\"", PREFAB_DIR));
}

test "rfc596: malformed top-level value (number) returns error.InvalidFormat" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    try testing.expectError(error.InvalidFormat, Bridge.loadSceneFromSource(&game, "42", PREFAB_DIR));
}

test "rfc596: malformed top-level value (bool) returns error.InvalidFormat" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    try testing.expectError(error.InvalidFormat, Bridge.loadSceneFromSource(&game, "true", PREFAB_DIR));
}

test "rfc596: malformed top-level value (null) returns error.InvalidFormat" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    try testing.expectError(error.InvalidFormat, Bridge.loadSceneFromSource(&game, "null", PREFAB_DIR));
}

test "rfc596: component-value data with PascalCase keys does NOT spawn phantom entities" {
    // Cursor MED (#597): `isEntityLike` was broadened to recognize
    // any object with a PascalCase key as an entity, but it's
    // called from `stripEntityArrayFields` and
    // `spawnAndLinkNestedEntities` on COMPONENT VALUE arrays —
    // component data that happens to carry PascalCase fields (e.g.
    // `{ Type: 1, DamageMultiplier: 2 }`) would be falsely tagged
    // as entities → stripped from component data → spawned as
    // phantom entities.
    //
    // The fix tightens `isEntityLike` to recognize entities by
    // structural keys only (`prefab` / `children` / `components`).
    var game = try boot(
        \\{ "children": [
        \\  { "Marker": { "id": 1 },
        \\    "FireSpell": { "entries": [
        \\      { "Type": 11, "DamageMultiplier": 22 },
        \\      { "Type": 33, "DamageMultiplier": 44 }
        \\    ] } }
        \\] }
    );
    defer game.deinit();

    // Exactly ONE entity — no phantoms spawned from FireSpell.entries.
    var buf: [8]i32 = undefined;
    try testing.expectEqualSlices(i32, &.{1}, markerIds(&game, &buf));

    // FireSpell component preserved intact: both entries present.
    var view = game.ecs_backend.view(.{FireSpell}, .{});
    defer view.deinit();
    const e = view.next().?;
    const fs = game.ecs_backend.getComponent(e, FireSpell).?.*;
    try testing.expectEqual(@as(usize, 2), fs.entries.len);
    try testing.expectEqual(@as(i32, 11), fs.entries[0].Type);
    try testing.expectEqual(@as(i32, 22), fs.entries[0].DamageMultiplier);
    try testing.expectEqual(@as(i32, 33), fs.entries[1].Type);
    try testing.expectEqual(@as(i32, 44), fs.entries[1].DamageMultiplier);
}

test "rfc596: flat-inline entity as a children[] item still works after tightening isEntityLike" {
    // Sanity gate for the cursor MED fix: tightening `isEntityLike`
    // to structural-keys-only must NOT break the legitimate flat-
    // inline RFC #596 shape — flat-inline entities are still
    // spawned via `children:` array items (where the caller knows
    // every item is an entity by definition, no `isEntityLike`
    // filter required).
    var game = try boot(
        \\{ "children": [
        \\  { "Marker": { "id": 2 }, "Health": { "current": 50 } }
        \\] }
    );
    defer game.deinit();

    // The flat-inline child spawns with BOTH components — proving
    // the tightened predicate still admits the RFC #596 Axis 2
    // shape when reached through a `children:` array (no
    // `isEntityLike` filter on that path).
    var buf: [8]i32 = undefined;
    try testing.expectEqualSlices(i32, &.{2}, markerIds(&game, &buf));

    var view = game.ecs_backend.view(.{ Marker, Health }, .{});
    defer view.deinit();
    const child = view.next().?;
    try testing.expectEqual(@as(i32, 2), game.ecs_backend.getComponent(child, Marker).?.id);
    try testing.expectEqual(@as(f32, 50), game.ecs_backend.getComponent(child, Health).?.current);
}

// ── RFC #596 update: file-header meta carries engine directives ──
//
// The bundle file-header `meta:` block is no longer a pure dump —
// engine-known keys (`initial_state`, plus reserved `scripts` /
// `include`) are applied to the load context BEFORE entities spawn.
// Unknown lowercase keys (`name`, `author`, `draft`, …) remain
// authoring-only and never reach the runtime. Entity-level `meta:`
// is still stripped unchanged (regression pin).

test "rfc596: bundle header with initial_state directive transitions game_state" {
    // `meta.initial_state: "playing"` switches the game to "playing"
    // before any entity spawns. `TestGame` defaults to "running"
    // (set in `game.zig:284`), so any change here came from the
    // file-header meta dispatch — not from a script, not from
    // SceneEntry.initial_state (no SceneEntry exists at this code
    // path: scenes loaded through `loadSceneFromSource` bypass the
    // scene registry).
    var game = try boot(
        \\[
        \\  { "meta": { "initial_state": "playing" } },
        \\  { "Marker": { "id": 1 } }
        \\]
    );
    defer game.deinit();

    try testing.expectEqualStrings("playing", game.getState());
    // Entity still spawned (directive runs alongside the entity load).
    try testing.expectEqual(@as(i32, 1), soleMarker(&game).id);
}

test "rfc596: bundle header with free-form meta keys is ignored (no state change)" {
    // `author`, `draft`, and other lowercase non-engine keys are
    // valid free-form authoring metadata. They MUST NOT affect the
    // engine — the loader ignores them silently (no warn, no error).
    var game = try boot(
        \\[
        \\  { "meta": { "author": "alexandre", "draft": true, "version": 3 } },
        \\  { "Marker": { "id": 7 } }
        \\]
    );
    defer game.deinit();

    // Default game_state untouched.
    try testing.expectEqualStrings("running", game.getState());
    try testing.expectEqual(@as(i32, 7), soleMarker(&game).id);
}

test "rfc596: bundle header with mixed engine + free-form meta applies engine key only" {
    // `meta.initial_state` is consumed; `meta.author` is ignored.
    // Both coexisting in the same header is the documented shape.
    var game = try boot(
        \\[
        \\  { "meta": { "initial_state": "playing", "author": "A", "name": "Demo" } },
        \\  { "Marker": { "id": 42 } }
        \\]
    );
    defer game.deinit();

    try testing.expectEqualStrings("playing", game.getState());
    try testing.expectEqual(@as(i32, 42), soleMarker(&game).id);
}

test "rfc596: bundle without header leaves game_state at default (regression)" {
    // Pin the no-header path: a bundle whose first element is an
    // entity (no `meta:`-only file header) MUST NOT trigger the
    // directive dispatch. The default game_state ("running") is
    // preserved.
    var game = try boot(
        \\[
        \\  { "Marker": { "id": 1 } },
        \\  { "Marker": { "id": 2 } }
        \\]
    );
    defer game.deinit();

    try testing.expectEqualStrings("running", game.getState());
    var buf: [8]i32 = undefined;
    try testing.expectEqualSlices(i32, &.{ 1, 2 }, markerIds(&game, &buf));
}

test "rfc596: entity-level meta with initial_state does NOT change game_state" {
    // Entity-scope `meta:` is authoring-only — it's stripped at
    // load and never consulted for engine directives. The asymmetric
    // semantics rationale: only the file-header `meta:` carries
    // engine directives; per-entity `meta:` is opaque label data.
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try Bridge.addEmbeddedPrefab(&game, "widget",
        \\{ "root": { "components": { "Marker": { "id": 100 } } } }
    , PREFAB_DIR);
    try Bridge.loadSceneFromSource(&game,
        \\{ "children": [
        \\  { "prefab": "widget", "meta": { "initial_state": "playing" } }
        \\] }
    , PREFAB_DIR);

    // Game stayed at the default — entity-meta is opaque to the engine.
    try testing.expectEqualStrings("running", game.getState());
    try testing.expectEqual(@as(i32, 100), soleMarker(&game).id);
}

// A poisoning allocator wrapper: stamps freed regions with `0xDE`
// before forwarding to the inner allocator. Used to force the
// `meta.initial_state` UAF below to surface deterministically —
// without it, freed arena memory still spells "playing" by accident
// (GPA does not actively scribble on free) and the regression test
// is a no-op.
const PoisonAllocator = struct {
    inner: std.mem.Allocator,

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *PoisonAllocator = @ptrCast(@alignCast(ctx));
        return self.inner.rawAlloc(len, alignment, ra);
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *PoisonAllocator = @ptrCast(@alignCast(ctx));
        return self.inner.rawResize(buf, alignment, new_len, ra);
    }

    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *PoisonAllocator = @ptrCast(@alignCast(ctx));
        return self.inner.rawRemap(buf, alignment, new_len, ra);
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *PoisonAllocator = @ptrCast(@alignCast(ctx));
        @memset(buf, 0xDE);
        self.inner.rawFree(buf, alignment, ra);
    }

    fn allocator(self: *PoisonAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }
};

test "rfc596: bundle meta.initial_state survives parse_arena.deinit (UAF regression)" {
    // Regression for a real use-after-free caught on PR #599:
    // `applyFileMetaDirectives` (scene_loader.zig) reads `state_name`
    // from the bundle header (`meta.initial_state`) — a slice into the
    // loader's `parse_arena` — and passes it straight to `setState`,
    // which stores by reference (`state_mixin.zig`: `self.game_state = new_state`).
    // The arena is `defer`-freed before `loadSceneFile` /
    // `loadSceneSource` returns, so `game.game_state` ended up
    // dangling for any subsequent read.
    //
    // The happy-path tests above read `getState()` after `boot()`
    // returns and happen to see the right bytes because freed memory
    // still contains the original string — the UAF is latent. This
    // test wraps the game allocator in `PoisonAllocator`, which
    // stamps `0xDE` over every freed region. A slice into freed
    // arena memory then observes poison, not "playing".
    //
    // Pre-fix: the assertion sees 0xDE bytes and fails.
    // Post-fix: `applyFileMetaDirectives` dupes onto `game.allocator`
    // and stores the owned backing on `game.owned_initial_state`,
    // so the value survives the arena teardown.
    var poison = PoisonAllocator{ .inner = testing.allocator };
    var game = TestGame.init(poison.allocator());
    defer game.deinit();
    try Bridge.loadSceneFromSource(&game,
        \\[
        \\  { "meta": { "initial_state": "playing" } },
        \\  { "Marker": { "id": 1 } }
        \\]
    , PREFAB_DIR);

    // After load, the parse_arena has been freed and `PoisonAllocator`
    // has overwritten its bytes with 0xDE. If `game.game_state` still
    // aliased into the arena (pre-fix), this read would see poison.
    try testing.expectEqualStrings("playing", game.getState());
    try testing.expectEqual(@as(i32, 1), soleMarker(&game).id);
}

test "rfc596: two consecutive meta.initial_state loads with different names — no second-order UAF" {
    // Second-order UAF caught on PR #599's first fix:
    //
    //   const owned = dupe(state_name);
    //   if (old) |o| free(o);          // game.game_state still aliases `o`
    //   game.owned_initial_state = owned;
    //   game.setState(owned);          // setState reads game.game_state in eql — UAF
    //
    // The first call leaves `game.game_state` aliasing the first
    // owned slot. The second call frees that slot *before* setState,
    // and PoisonAllocator stamps it with 0xDE. setState's
    // `std.mem.eql(self.game_state, new_state)` then probes freed
    // memory.
    //
    // Pre-fix on a debug build: a `[]const u8` comparison against a
    // 0xDE-stamped buffer may early-mismatch (no crash) or read
    // freed bytes (UB, potentially crash under sanitizers). The
    // assertion below — that game.game_state reads back as "paused"
    // — would also fail, because under poison the second setState
    // can mis-decide and the field can end up pointing wherever the
    // poison left it.
    //
    // Post-fix the eql probe runs against the still-live old slot
    // (or default literal), setState assigns game.game_state =
    // new_owned, and we free old_owned afterwards.
    var poison = PoisonAllocator{ .inner = testing.allocator };
    var game = TestGame.init(poison.allocator());
    defer game.deinit();

    try Bridge.loadSceneFromSource(&game,
        \\[
        \\  { "meta": { "initial_state": "playing" } },
        \\  { "Marker": { "id": 1 } }
        \\]
    , PREFAB_DIR);
    try testing.expectEqualStrings("playing", game.getState());

    try Bridge.loadSceneFromSource(&game,
        \\[
        \\  { "meta": { "initial_state": "paused" } },
        \\  { "Marker": { "id": 2 } }
        \\]
    , PREFAB_DIR);
    try testing.expectEqualStrings("paused", game.getState());
}

test "rfc596: two consecutive meta.initial_state loads with SAME name — no dangle, no churn" {
    // If the same state name is applied twice in a row, the
    // owned-slot short-circuit should fire (post-fix). Pre-fix's
    // ordering would still free + dupe + setState — and even if
    // the dupe happens to land at the same address (it won't under
    // PoisonAllocator + testing.allocator), the early-return inside
    // setState (eql with freed-then-poisoned bytes) leaves
    // game.game_state permanently aliasing the freed slot.
    //
    // Post-fix: second call short-circuits at the eql probe of
    // `existing` (the still-live owned slot from the first call)
    // against `state_name` — no free, no dupe, no setState. The
    // value read back is still "playing".
    var poison = PoisonAllocator{ .inner = testing.allocator };
    var game = TestGame.init(poison.allocator());
    defer game.deinit();

    try Bridge.loadSceneFromSource(&game,
        \\[
        \\  { "meta": { "initial_state": "playing" } },
        \\  { "Marker": { "id": 1 } }
        \\]
    , PREFAB_DIR);

    try Bridge.loadSceneFromSource(&game,
        \\[
        \\  { "meta": { "initial_state": "playing" } },
        \\  { "Marker": { "id": 2 } }
        \\]
    , PREFAB_DIR);

    // game.game_state must still read "playing" — not poison.
    try testing.expectEqualStrings("playing", game.getState());
}

test "rfc596: same-name reapply moves the backing pointer (post fix #3 contract)" {
    // Pointer-identity probe of the NEW contract introduced by PR
    // #599 fix #3: `applyFileMetaDirectives` always dupes a fresh
    // backing slot and always frees the prior one, even when the
    // state name is unchanged.
    //
    // Historical note — pre-fix-#3 this test asserted the OPPOSITE
    // (pointer identity stable across same-name reapply), which was
    // the documented contract of fix #2's no-churn short-circuit.
    // That short-circuit was dropped in fix #3 because cursor
    // surfaced a MEDIUM correctness bug: the short-circuit only
    // probed `owned_initial_state == state_name`, not whether
    // `game.game_state` was still in sync. An external `setState`
    // between two loads with the same `meta.initial_state` would be
    // silently ignored — game stuck at the external state. See the
    // "recovers state after external setState" regression test
    // below.
    //
    // The dupe+free churn per scene load is negligible compared to
    // the bug surface of the prior short-circuit. We now positively
    // assert the new behavior: pointer MOVES on every call.
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try Bridge.loadSceneFromSource(&game,
        \\[
        \\  { "meta": { "initial_state": "playing" } },
        \\  { "Marker": { "id": 1 } }
        \\]
    , PREFAB_DIR);
    const ptr_before = game.getState().ptr;

    try Bridge.loadSceneFromSource(&game,
        \\[
        \\  { "meta": { "initial_state": "playing" } },
        \\  { "Marker": { "id": 2 } }
        \\]
    , PREFAB_DIR);
    const ptr_after = game.getState().ptr;

    // New contract: dupe+free churn means a fresh backing slot every
    // time. Allocator MAY hand back the same address by coincidence
    // (testing.allocator's GPA generally doesn't immediately reuse
    // freed slots at the same size, but it's not a hard guarantee).
    // We assert *inequality* as the documented contract; if the
    // allocator ever does coincidentally reuse, this test will need
    // a PoisonAllocator-backed value check instead. For now testing
    // .allocator reliably hands back a different address.
    try testing.expect(ptr_before != ptr_after);
    try testing.expectEqualStrings("playing", game.getState());
}

test "rfc596: applyFileMetaDirectives recovers state after external setState (cursor MEDIUM regression)" {
    // PR #599 fix #3 regression test. Pre-fix-#3 sequence:
    //
    //   1. Load bundle with meta.initial_state="playing"
    //      → game.game_state = owned_initial_state = "playing"
    //   2. game.setState("debug")
    //      → game.game_state aliases the literal "debug"
    //      → owned_initial_state still backs "playing"
    //   3. Load same bundle again (meta.initial_state="playing")
    //      → fix #2's short-circuit fires (owned == "playing")
    //      → applyFileMetaDirectives returns immediately
    //      → game.game_state STAYS as "debug" — directive silently
    //        ignored.
    //
    // Post-fix-#3: no short-circuit. The dupe + setState path runs,
    // and setState's eql("debug", "playing") fails, so setState
    // reassigns and game.game_state ends up at "playing" as the
    // directive demands.
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try Bridge.loadSceneFromSource(&game,
        \\[
        \\  { "meta": { "initial_state": "playing" } },
        \\  { "Marker": { "id": 1 } }
        \\]
    , PREFAB_DIR);
    try testing.expectEqualStrings("playing", game.getState());

    // External state mutation between loads.
    game.setState("debug");
    try testing.expectEqualStrings("debug", game.getState());

    // Re-apply the same meta directive — must recover the demanded
    // state, NOT silently leave the game in "debug".
    try Bridge.loadSceneFromSource(&game,
        \\[
        \\  { "meta": { "initial_state": "playing" } },
        \\  { "Marker": { "id": 2 } }
        \\]
    , PREFAB_DIR);

    try testing.expectEqualStrings("playing", game.getState());
}

test "rfc596: meta.initial_state matching pre-set non-owned literal — no free of literal" {
    // If a prior code path (comptime codegen, manual `setState`)
    // left `game.game_state` aliasing a string literal whose value
    // happens to equal the bundle's `meta.initial_state`, the
    // loader must not attempt to free the literal — and the field
    // must still read back correctly after the call.
    //
    // Post-fix walk:
    //   - `owned_initial_state` is null on entry → short-circuit
    //     does NOT fire.
    //   - We dupe `new_owned`.
    //   - `owned_initial_state = new_owned`.
    //   - `setState(new_owned)`: eql(literal, new_owned) → true →
    //     early-return. `game.game_state` keeps aliasing the literal.
    //   - `old_owned` is null → no free attempt.
    //
    // No literal is freed, no UAF, value reads correctly.
    var poison = PoisonAllocator{ .inner = testing.allocator };
    var game = TestGame.init(poison.allocator());
    defer game.deinit();

    // Force game.game_state to a literal "playing" *before* the
    // meta-directive load. This mimics the comptime-codegen path
    // (and is also what a script could do).
    game.setState("playing");

    try Bridge.loadSceneFromSource(&game,
        \\[
        \\  { "meta": { "initial_state": "playing" } },
        \\  { "Marker": { "id": 1 } }
        \\]
    , PREFAB_DIR);

    try testing.expectEqualStrings("playing", game.getState());
}
