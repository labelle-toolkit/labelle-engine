//! zspec BDD specs for `overrides` merge semantics (RFC #560,
//! ticket #562).
//!
//! `overrides` on a prefab reference deep-merges onto the prefab's
//! components:
//!  - objects merge recursively — a field the override omits keeps
//!    the prefab's value;
//!  - arrays and scalars replace outright;
//!  - a component whose override value is `null` is removed.
//!
//! See RFC-OVERRIDES-MERGE-RULES.md.

const std = @import("std");
const zspec = @import("zspec");
const engine = @import("engine");

const expect = zspec.expect;
const Factory = zspec.Factory;
const Fixture = zspec.Fixture;

// ── Components under test ───────────────────────────────────────

const Marker = struct { id: i32 = 0 };
const Health = struct { current: f32 = 0, max: f32 = 100 };

/// Nested struct — exercises recursive object merge.
const Size = struct { w: f32 = 0, h: f32 = 0 };
const Box = struct { size: Size = .{}, label_len: i32 = 0 };

/// Plain (non-entity) slice field — exercises array replacement.
const Tags = struct { values: []const i32 = &.{} };

/// Entity-bearing `slots` plus a scalar `tag` — exercises a
/// deep-merged component keeping its prefab's nested entities.
const Container = struct { slots: []const u64 = &.{}, tag: i32 = 0 };

const Components = engine.ComponentRegistry(.{
    .Marker = Marker,
    .Health = Health,
    .Box = Box,
    .Tags = Tags,
    .Container = Container,
});

const Game = engine.Game;
const Bridge = engine.JsoncSceneBridge(Game, Components);

const HealthFactory = Factory.define(Health, .{ .current = 0, .max = 100 });

// ── Fixture: prefab corpus ──────────────────────────────────────

const Sources = struct {
    /// Two-field component — for field-level inheritance.
    health: []const u8,
    /// Nested struct + scalar — for recursive merge.
    box: []const u8,
    /// Plain slice field — for array replacement.
    tags: []const u8,
    /// Two components — for removal + sibling survival.
    pair: []const u8,
    /// Entity-bearing `slots` + scalar — for merged-component
    /// nested-entity survival.
    container: []const u8,
};

const Corpus = Fixture.define(Sources, .{
    .health =
    \\{ "root": { "components": { "Health": { "current": 80, "max": 100 } } } }
    ,
    .box =
    \\{ "root": { "components": {
    \\  "Box": { "size": { "w": 1, "h": 2 }, "label_len": 5 }
    \\} } }
    ,
    .tags =
    \\{ "root": { "components": { "Tags": { "values": [1, 2, 3] } } } }
    ,
    .pair =
    \\{ "root": { "components": {
    \\  "Marker": { "id": 99 },
    \\  "Health": { "current": 50, "max": 70 }
    \\} } }
    ,
    .container =
    \\{ "root": { "components": {
    \\  "Marker": { "id": 99 },
    \\  "Container": { "tag": 1, "slots": [
    \\    { "components": { "Marker": { "id": 1 } } }
    \\  ] }
    \\} } }
    ,
});

const PREFAB_DIR = "/tmp/labelle-nonexistent-spec-562";

/// The sole entity carrying component `T` (asserts exactly one).
fn sole(game: *Game, comptime T: type) *T {
    var view = game.ecs_backend.view(.{T}, .{});
    defer view.deinit();
    const e = view.next().?;
    std.debug.assert(view.next() == null);
    return game.ecs_backend.getComponent(e, T).?;
}

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

pub const OverrideMergeSpec = struct {
    var game: Game = undefined;

    test "tests:before" {
        game = Game.init(zspec.allocator);
    }

    test "tests:after" {
        game.deinit();
    }

    // ── Deep field-level merge ──────────────────────────────────

    pub const @"a component named in overrides deep-merges over the prefab" = struct {
        test "tests:before" {
            const src = Corpus.create(.{});
            try Bridge.addEmbeddedPrefab(&game, "health", src.health, PREFAB_DIR);
            try Bridge.addEmbeddedPrefab(&game, "box", src.box, PREFAB_DIR);
            try Bridge.addEmbeddedPrefab(&game, "tags", src.tags, PREFAB_DIR);
        }

        test "a field the override omits keeps the prefab's value" {
            try Bridge.loadSceneFromSource(&game,
                \\{ "root": { "children": [
                \\  { "prefab": "health", "overrides": { "Health": { "current": 30 } } }
                \\] } }
            , PREFAB_DIR);
            // current overridden; max inherited from the prefab.
            try std.testing.expectEqual(
                HealthFactory.build(.{ .current = 30, .max = 100 }),
                sole(&game, Health).*,
            );
        }

        test "merge recurses into nested struct fields" {
            try Bridge.loadSceneFromSource(&game,
                \\{ "root": { "children": [
                \\  { "prefab": "box", "overrides": { "Box": { "size": { "w": 9 } } } }
                \\] } }
            , PREFAB_DIR);
            const box = sole(&game, Box);
            // size.w overridden; size.h and label_len inherited.
            try expect.equal(box.size.w, 9);
            try expect.equal(box.size.h, 2);
            try expect.equal(box.label_len, 5);
        }

        test "an array field is replaced outright, not element-merged" {
            try Bridge.loadSceneFromSource(&game,
                \\{ "root": { "children": [
                \\  { "prefab": "tags", "overrides": { "Tags": { "values": [9] } } }
                \\] } }
            , PREFAB_DIR);
            const tags = sole(&game, Tags);
            try expect.equal(tags.values.len, 1);
            try expect.equal(tags.values[0], 9);
        }
    };

    // ── Component removal via null ──────────────────────────────

    pub const @"a null override removes a component" = struct {
        test "tests:before" {
            const src = Corpus.create(.{});
            try Bridge.addEmbeddedPrefab(&game, "pair", src.pair, PREFAB_DIR);
        }

        test "the named component is dropped from the instance" {
            try Bridge.loadSceneFromSource(&game,
                \\{ "root": { "children": [
                \\  { "prefab": "pair", "overrides": { "Marker": null } }
                \\] } }
            , PREFAB_DIR);
            var view = game.ecs_backend.view(.{Health}, .{});
            defer view.deinit();
            const e = view.next().?;
            try expect.toBeNull(game.ecs_backend.getComponent(e, Marker));
        }

        test "sibling components the override leaves alone survive" {
            try Bridge.loadSceneFromSource(&game,
                \\{ "root": { "children": [
                \\  { "prefab": "pair", "overrides": { "Marker": null } }
                \\] } }
            , PREFAB_DIR);
            // Health untouched — kept verbatim from the prefab.
            try std.testing.expectEqual(
                HealthFactory.build(.{ .current = 50, .max = 70 }),
                sole(&game, Health).*,
            );
        }
    };

    // ── `null` is removal only for a reference's overrides ──────

    pub const @"a null in an inline entity's components is not a removal" = struct {
        // No prefab registered — these are pure inline entities
        // (no `prefab` key), so their `components` block is not an
        // `overrides` block and carries no removal semantics.

        test "a null component does not suppress sibling inline components" {
            // RFC #562 scopes `null`-as-removal to a reference
            // entry's `overrides`. An inline `components` `null` is
            // just a (malformed) value — it must not delete the
            // entity or silence its other components.
            try Bridge.loadSceneFromSource(&game,
                \\{ "root": { "children": [
                \\  { "components": { "Marker": null, "Health": { "current": 7, "max": 9 } } }
                \\] } }
            , PREFAB_DIR);
            // The sibling Health component still applies normally.
            try std.testing.expectEqual(
                HealthFactory.build(.{ .current = 7, .max = 9 }),
                sole(&game, Health).*,
            );
        }
    };

    // ── Merged component keeps its prefab's entity fields ───────

    pub const @"deep-merging a component preserves its entity-bearing fields" = struct {
        test "tests:before" {
            const src = Corpus.create(.{});
            try Bridge.addEmbeddedPrefab(&game, "container", src.container, PREFAB_DIR);
        }

        test "overriding one field still spawns the prefab's nested entities" {
            try Bridge.loadSceneFromSource(&game,
                \\{ "root": { "children": [
                \\  { "prefab": "container", "overrides": { "Container": { "tag": 5 } } }
                \\] } }
            , PREFAB_DIR);
            // tag patched; slots inherited from the prefab, so its
            // nested Marker entity must still spawn.
            try expect.equal(sole(&game, Container).tag, 5);
            try expect.notToBeNull(findMarker(&game, 1)); // nested entity
            try expect.notToBeNull(findMarker(&game, 99)); // root entity
        }
    };
};
