//! zspec BDD specs for the unified prefab/scene loader (RFC #560,
//! ticket #561).
//!
//! Covers the paths the std.testing suite in
//! `test/jsonc/unified_format_test.zig` does not reach — every one a
//! place `scene_loader.zig` was edited:
//!
//!  - runtime `spawnFromPrefab` of a `root`-wrapped prefab,
//!  - prefab references nested inside entity-bearing component
//!    fields (the `Room.movement_nodes` pattern) under the unified
//!    format,
//!  - a reference entry carrying both `overrides` and a legacy
//!    `components` key.

const std = @import("std");
const zspec = @import("zspec");
const engine = @import("engine");
const core = @import("labelle-core");

const expect = zspec.expect;
const Factory = zspec.Factory;
const Fixture = zspec.Fixture;

// ── Components under test ───────────────────────────────────────

const Marker = struct { id: i32 = 0 };
const Health = struct { current: f32 = 0, max: f32 = 100 };

/// Holds nested entities via a `[]const u64` ref-array — the shape
/// `Room.workstations` / `movement_nodes` use. The loader detects
/// the array as entity-bearing, spawns each item, and patches the
/// resulting IDs back in.
const Container = struct { slots: []const u64 = &.{} };

const Components = engine.ComponentRegistry(.{
    .Marker = Marker,
    .Health = Health,
    .Container = Container,
});

const Game = engine.Game;
const Bridge = engine.JsoncSceneBridge(Game, Components);

// ── Factory: expected component values ──────────────────────────
//
// `MarkerFactory.build(.{ .id = N })` yields a `Marker` with every
// other field defaulted — the expected struct a loaded component is
// compared against, rather than reaching into one field at a time.
const MarkerFactory = Factory.define(Marker, .{ .id = 0 });

// ── Fixture: the JSONC test corpus ──────────────────────────────
//
// Static, known-good prefab and scene sources. `Corpus.create(.{})`
// hands back the struct; a test reads the field it needs (or
// overrides it via `create(.{ .field = "..." })`).

const Sources = struct {
    /// Unified prefab — `root` wrapper, components only.
    widget: []const u8,
    /// Unified prefab — `root` wrapper with components AND children.
    parent: []const u8,
    /// Unified prefab used as a nested-array item.
    nested_item: []const u8,
    /// Unified prefab for the override-precedence scene.
    base: []const u8,
    /// Empty unified scene — bootstraps `game.spawn_prefab_fn`.
    empty_scene: []const u8,
};

const Corpus = Fixture.define(Sources, .{
    .widget =
    \\{ "root": { "components": { "Marker": { "id": 100 } } } }
    ,
    .parent =
    \\{ "root": {
    \\  "components": { "Marker": { "id": 1 } },
    \\  "children": [ { "components": { "Marker": { "id": 2 } } } ]
    \\} }
    ,
    .nested_item =
    \\{ "root": { "components": { "Marker": { "id": 500 } } } }
    ,
    .base =
    \\{ "root": { "components": { "Marker": { "id": 1 } } } }
    ,
    .empty_scene =
    \\{ "root": { "children": [] } }
    ,
});

// A path with no `prefabs/` directory — every prefab must come from
// `addEmbeddedPrefab`, never a filesystem fallback.
const PREFAB_DIR = "/tmp/labelle-nonexistent-spec-561";

/// First entity carrying a `Marker` with the given id, or null.
fn findMarker(game: *Game, id: i32) ?*Marker {
    var view = game.ecs_backend.view(.{Marker}, .{});
    defer view.deinit();
    while (view.next()) |e| {
        const m = game.ecs_backend.getComponent(e, Marker).?;
        if (m.id == id) return m;
    }
    return null;
}

/// Count of entities carrying a `Marker`.
fn countMarkers(game: *Game) usize {
    var view = game.ecs_backend.view(.{Marker}, .{});
    defer view.deinit();
    var n: usize = 0;
    while (view.next()) |_| n += 1;
    return n;
}

pub const UnifiedFormatSpec = struct {
    var game: Game = undefined;

    // Outer hooks own the game's lifetime; each `describe` group's
    // own `tests:before` then embeds the prefabs that group needs.
    test "tests:before" {
        game = Game.init(zspec.allocator);
    }

    test "tests:after" {
        game.deinit();
    }

    // ── spawnFromPrefab — runtime instantiation ─────────────────

    pub const @"spawnFromPrefab instantiates a unified prefab" = struct {
        test "tests:before" {
            const src = Corpus.create(.{});
            try Bridge.addEmbeddedPrefab(&game, "widget", src.widget, PREFAB_DIR);
            try Bridge.addEmbeddedPrefab(&game, "parent", src.parent, PREFAB_DIR);
            // Loading any scene wires `game.spawn_prefab_fn`.
            try Bridge.loadSceneFromSource(&game, src.empty_scene, PREFAB_DIR);
        }

        test "applies the root-wrapped components to the spawned entity" {
            const e = game.spawnFromPrefab("widget", .{ .x = 0, .y = 0 }).?;
            const marker = game.ecs_backend.getComponent(e, Marker).?;
            // zspec's `expect.equal` compares with `==` (no struct
            // support); the whole-struct check goes through
            // `std.testing.expectEqual`, fed the factory-built
            // expectation.
            try std.testing.expectEqual(MarkerFactory.build(.{ .id = 100 }), marker.*);
        }

        test "instantiates the prefab's root.children subtree" {
            _ = game.spawnFromPrefab("parent", .{ .x = 0, .y = 0 }).?;
            // Root (Marker 1) plus its one child (Marker 2).
            try expect.notToBeNull(findMarker(&game, 1));
            try expect.notToBeNull(findMarker(&game, 2));
            try expect.equal(countMarkers(&game), 2);
        }
    };

    // ── prefab refs inside entity-bearing component fields ──────

    pub const @"nested prefab references inside component fields" = struct {
        test "tests:before" {
            const src = Corpus.create(.{});
            try Bridge.addEmbeddedPrefab(&game, "nested_item", src.nested_item, PREFAB_DIR);
        }

        test "a unified prefab referenced via overrides is spawned and patched" {
            try Bridge.loadSceneFromSource(&game,
                \\{ "root": { "children": [
                \\  { "components": { "Container": { "slots": [
                \\    { "prefab": "nested_item", "overrides": { "Marker": { "id": 7 } } }
                \\  ] } } }
                \\] } }
            , PREFAB_DIR);

            // The nested item spawned with the override applied (7),
            // not the prefab default (500).
            try expect.notToBeNull(findMarker(&game, 7));
            try expect.toBeNull(findMarker(&game, 500));
        }

        test "legacy components on a nested reference still resolves" {
            try Bridge.loadSceneFromSource(&game,
                \\{ "root": { "children": [
                \\  { "components": { "Container": { "slots": [
                \\    { "prefab": "nested_item", "components": { "Marker": { "id": 8 } } }
                \\  ] } } }
                \\] } }
            , PREFAB_DIR);

            try expect.notToBeNull(findMarker(&game, 8));
        }
    };

    // ── reference entry: overrides vs. legacy components ────────

    pub const @"a reference carrying both overrides and components" = struct {
        test "tests:before" {
            const src = Corpus.create(.{});
            try Bridge.addEmbeddedPrefab(&game, "base", src.base, PREFAB_DIR);
        }

        test "overrides wins over a legacy components key on the same entry" {
            try Bridge.loadSceneFromSource(&game,
                \\{ "root": { "children": [
                \\  { "prefab": "base",
                \\    "overrides":  { "Marker": { "id": 9  } },
                \\    "components": { "Marker": { "id": 99 } } }
                \\] } }
            , PREFAB_DIR);

            try expect.notToBeNull(findMarker(&game, 9));
            try expect.toBeNull(findMarker(&game, 99));
        }
    };
};
