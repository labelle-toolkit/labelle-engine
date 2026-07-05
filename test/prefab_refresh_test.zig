//! Bounded live-instance prefab refresh (#691) —
//! `jsonc/scene_loader/prefab_refresh.zig` through the public
//! `reloadPrefabSource` seam (the same path `editor_reload_prefab`
//! drives, minus the vtable plumbing `editor_api_test.zig` covers).
//!
//! The scope contract under test:
//!   * `.transient` registry components declared by the prefab are
//!     re-applied in place on live instances; `.saveable` runtime
//!     state is never touched.
//!   * Runtime-attached transients (keys the JSON never declared)
//!     survive a push — the diff is declared-keys, not entity state.
//!   * A declared transient key DROPPED by the new source is removed.
//!   * Children resolve through `PrefabChild.local_path` against both
//!     generations in lockstep; a child-count change skips the child
//!     (structural edits need a respawn), the root still refreshes.
//!   * Reference-mode children re-merge `overrides` onto the
//!     referenced prefab's CURRENT definition when the DECLARING
//!     prefab is pushed; pushing the referenced prefab leaves them
//!     alone (documented gap — future spawns converge).
//!   * Entity-ref fields (`[]const u64` + declared `entity_refs`)
//!     survive the re-deserialize.
//!   * `onReady` fires per re-applied key, exactly like a Phase 1
//!     respawn.
//!   * Instances of OTHER prefabs never refresh.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const core = @import("labelle-core");

var ready_count: usize = 0;

/// Transient visual-ish component — the SpriteAnimation stand-in. The
/// string field pins tree lifetime: after a push it must read the NEW
/// tree's bytes on refreshed instances.
const Overlay = struct {
    pub const save = core.Saveable(.transient, @This(), .{});
    fps: f32 = 0,
    text: []const u8 = "",

    pub fn onReady(payload: anytype) void {
        _ = payload;
        ready_count += 1;
    }
};

/// Saveable game state — refresh must never write it.
const Keep = struct {
    pub const save = core.Saveable(.saveable, @This(), .{});
    hp: i32 = 0,
};

/// Transient toggled by "game code" at runtime (FP's condenser-gate
/// shape) and also usable as a declared-then-dropped key.
const Gate = struct {
    pub const save = core.Saveable(.transient, @This(), .{});
    n: i32 = 0,
};

/// Transient carrying entity refs — the fields the spawn path patches
/// AFTER apply, which a naive re-deserialize would zero.
const Links = struct {
    pub const save = core.Saveable(.transient, @This(), .{ .entity_refs = &.{"owner"} });
    fps: f32 = 0,
    owner: u64 = 0,
    links: []const u64 = &.{},
};

const Components = engine.ComponentRegistry(.{
    .Overlay = Overlay,
    .Keep = Keep,
    .Gate = Gate,
    .Links = Links,
});

const Bridge = engine.JsoncSceneBridge(engine.Game, Components);

fn boot(game: *engine.Game, prefabs: []const struct { name: []const u8, src: []const u8 }) !void {
    for (prefabs) |p| {
        try Bridge.addEmbeddedPrefab(game, p.name, p.src, "prefabs");
    }
    try Bridge.loadSceneFromSource(game,
        \\{ "entities": [] }
    , "prefabs");
}

// ── Root instances ──────────────────────────────────────────────────

test "root: declared transients re-apply in place; saveable runtime state and the retired tree's readers stay untouched" {
    var game = engine.Game.init(testing.allocator);
    defer game.deinit();
    try boot(&game, &.{.{ .name = "condenser", .src =
        \\{ "components": {
        \\    "Overlay": { "fps": 6.0, "text": "v1" },
        \\    "Keep": { "hp": 3 }
        \\} }
    }});

    const e = game.spawnPrefab("condenser", .{ .x = 0, .y = 0 }).?;
    // Runtime progression on the SAVEABLE component — must survive.
    game.ecs_backend.getComponent(e, Keep).?.hp = 99;

    try game.reloadPrefabSource("condenser",
        \\{ "components": {
        \\    "Overlay": { "fps": 24.0, "text": "v2" },
        \\    "Keep": { "hp": 3 }
        \\} }
    );

    const o = game.ecs_backend.getComponent(e, Overlay).?;
    try testing.expectEqual(@as(f32, 24.0), o.fps);
    try testing.expectEqualStrings("v2", o.text); // NEW tree's bytes
    // `.saveable` is not in the refresh set — runtime state intact.
    try testing.expectEqual(@as(i32, 99), game.ecs_backend.getComponent(e, Keep).?.hp);
}

test "root: runtime-attached transient (never declared) survives a push; dropped DECLARED key is removed" {
    var game = engine.Game.init(testing.allocator);
    defer game.deinit();
    try boot(&game, &.{.{ .name = "condenser", .src =
        \\{ "components": {
        \\    "Overlay": { "fps": 6.0 },
        \\    "Gate": { "n": 1 }
        \\} }
    }});

    const e = game.spawnPrefab("condenser", .{ .x = 0, .y = 0 }).?;
    // Game code attaches its own transient — the condenser-gate shape.
    game.addComponent(e, Links{ .fps = 7.0 });

    // v2 drops the DECLARED `Gate`; `Links` was never declared.
    try game.reloadPrefabSource("condenser",
        \\{ "components": { "Overlay": { "fps": 24.0 } } }
    );

    // Declared-and-dropped → removed (a fresh spawn wouldn't have it).
    try testing.expect(game.ecs_backend.getComponent(e, Gate) == null);
    // Runtime-attached → invisible to the declared-key diff.
    try testing.expectEqual(@as(f32, 7.0), game.ecs_backend.getComponent(e, Links).?.fps);
    try testing.expectEqual(@as(f32, 24.0), game.ecs_backend.getComponent(e, Overlay).?.fps);
}

test "root: instances of OTHER prefabs never refresh; a fresh spawn uses the new data" {
    var game = engine.Game.init(testing.allocator);
    defer game.deinit();
    try boot(&game, &.{
        .{ .name = "a", .src =
        \\{ "components": { "Overlay": { "fps": 6.0 } } }
        },
        .{ .name = "b", .src =
        \\{ "components": { "Overlay": { "fps": 6.0 } } }
        },
    });

    const ea = game.spawnPrefab("a", .{ .x = 0, .y = 0 }).?;
    const eb = game.spawnPrefab("b", .{ .x = 0, .y = 0 }).?;

    try game.reloadPrefabSource("a",
        \\{ "components": { "Overlay": { "fps": 24.0 } } }
    );

    try testing.expectEqual(@as(f32, 24.0), game.ecs_backend.getComponent(ea, Overlay).?.fps);
    try testing.expectEqual(@as(f32, 6.0), game.ecs_backend.getComponent(eb, Overlay).?.fps);

    const ea2 = game.spawnPrefab("a", .{ .x = 0, .y = 0 }).?;
    try testing.expectEqual(@as(f32, 24.0), game.ecs_backend.getComponent(ea2, Overlay).?.fps);
}

test "root: entity-ref fields survive the re-deserialize; onReady fires per re-applied key" {
    var game = engine.Game.init(testing.allocator);
    defer game.deinit();
    try boot(&game, &.{.{ .name = "holder", .src =
        \\{ "components": {
        \\    "Overlay": { "fps": 6.0 },
        \\    "Links": { "fps": 6.0 }
        \\} }
    }});

    const e = game.spawnPrefab("holder", .{ .x = 0, .y = 0 }).?;
    // The spawn path patches refs AFTER apply (patchEntityIdField);
    // simulate that post-spawn wiring.
    const wired = [_]u64{ 11, 22 };
    {
        const l = game.ecs_backend.getComponent(e, Links).?;
        l.owner = 5;
        l.links = &wired;
    }

    ready_count = 0;
    try game.reloadPrefabSource("holder",
        \\{ "components": {
        \\    "Overlay": { "fps": 24.0 },
        \\    "Links": { "fps": 24.0 }
        \\} }
    );

    const l = game.ecs_backend.getComponent(e, Links).?;
    try testing.expectEqual(@as(f32, 24.0), l.fps); // value re-applied
    try testing.expectEqual(@as(u64, 5), l.owner); // declared entity_ref
    try testing.expectEqualSlices(u64, &wired, l.links); // []const u64
    // Overlay is the only registered type with onReady — one re-apply,
    // one fire (load-consistent: Phase 1 respawn fires it too).
    try testing.expectEqual(@as(usize, 1), ready_count);
}

// ── Children ────────────────────────────────────────────────────────

test "child: inline child transients re-apply through local_path; a child-count change skips the child but not the root" {
    var game = engine.Game.init(testing.allocator);
    defer game.deinit();
    try boot(&game, &.{.{ .name = "station", .src =
        \\{
        \\  "components": { "Overlay": { "fps": 6.0 } },
        \\  "children": [
        \\    { "components": { "Overlay": { "fps": 6.0, "text": "plant-v1" } } }
        \\  ]
        \\}
    }});

    const root = game.spawnPrefab("station", .{ .x = 0, .y = 0 }).?;
    const child = game.getChildren(root)[0];

    // Same shape → child refreshes.
    try game.reloadPrefabSource("station",
        \\{
        \\  "components": { "Overlay": { "fps": 12.0 } },
        \\  "children": [
        \\    { "components": { "Overlay": { "fps": 30.0, "text": "plant-v2" } } }
        \\  ]
        \\}
    );
    try testing.expectEqual(@as(f32, 30.0), game.ecs_backend.getComponent(child, Overlay).?.fps);
    try testing.expectEqualStrings("plant-v2", game.ecs_backend.getComponent(child, Overlay).?.text);

    // Child count changed (structural edit) → the length gate skips
    // the child; the ROOT still refreshes; no phantom child spawns.
    try game.reloadPrefabSource("station",
        \\{
        \\  "components": { "Overlay": { "fps": 48.0 } },
        \\  "children": [
        \\    { "components": { "Overlay": { "fps": 60.0 } } },
        \\    { "components": { "Overlay": { "fps": 60.0 } } }
        \\  ]
        \\}
    );
    try testing.expectEqual(@as(f32, 48.0), game.ecs_backend.getComponent(root, Overlay).?.fps);
    try testing.expectEqual(@as(f32, 30.0), game.ecs_backend.getComponent(child, Overlay).?.fps);
    try testing.expectEqual(@as(usize, 1), game.getChildren(root).len);
}

test "child: reference-mode child re-merges overrides onto the referenced prefab when the DECLARING prefab is pushed; pushing the referenced prefab leaves it alone" {
    var game = engine.Game.init(testing.allocator);
    defer game.deinit();
    try boot(&game, &.{
        .{ .name = "leaf", .src =
        \\{ "components": { "Overlay": { "fps": 6.0, "text": "leaf" } } }
        },
        .{ .name = "wrap", .src =
        \\{
        \\  "components": { "Keep": { "hp": 1 } },
        \\  "children": [
        \\    { "prefab": "leaf", "overrides": { "Overlay": { "fps": 99.0 } } }
        \\  ]
        \\}
        },
    });

    const root = game.spawnPrefab("wrap", .{ .x = 0, .y = 0 }).?;
    const child = game.getChildren(root)[0];
    try testing.expectEqual(@as(f32, 99.0), game.ecs_backend.getComponent(child, Overlay).?.fps);

    // Push the DECLARING prefab: override deep-merges onto leaf's
    // current components — patched field updates, base field stays.
    try game.reloadPrefabSource("wrap",
        \\{
        \\  "components": { "Keep": { "hp": 1 } },
        \\  "children": [
        \\    { "prefab": "leaf", "overrides": { "Overlay": { "fps": 77.0 } } }
        \\  ]
        \\}
    );
    {
        const o = game.ecs_backend.getComponent(child, Overlay).?;
        try testing.expectEqual(@as(f32, 77.0), o.fps);
        try testing.expectEqualStrings("leaf", o.text);
    }

    // Push the REFERENCED prefab: the child also carries its own
    // `PrefabInstance("leaf")` tag, but the root pass must skip
    // `PrefabChild` carriers — otherwise leaf's base values would
    // clobber the override merge. Documented gap: it doesn't refresh.
    try game.reloadPrefabSource("leaf",
        \\{ "components": { "Overlay": { "fps": 1.0, "text": "leaf-v2" } } }
    );
    {
        const o = game.ecs_backend.getComponent(child, Overlay).?;
        try testing.expectEqual(@as(f32, 77.0), o.fps);
        try testing.expectEqualStrings("leaf", o.text);
    }
}

// ── Keying / lifecycle edges ────────────────────────────────────────

test "effective-name alias: a push whose source names an installed key refreshes that key's instances" {
    var game = engine.Game.init(testing.allocator);
    defer game.deinit();
    try boot(&game, &.{.{ .name = "vent", .src =
        \\{ "components": { "Overlay": { "fps": 6.0 } } }
    }});

    const e = game.spawnPrefab("vent", .{ .x = 0, .y = 0 }).?;

    // Studio pushes under the file stem, the source's `"name"` field
    // targets the installed key (RFC #561 effective naming).
    try game.reloadPrefabSource("whatever",
        \\{ "name": "vent", "components": { "Overlay": { "fps": 24.0 } } }
    );
    try testing.expectEqual(@as(f32, 24.0), game.ecs_backend.getComponent(e, Overlay).?.fps);
}

test "insert (no previous generation) and invalid pushes touch nothing" {
    var game = engine.Game.init(testing.allocator);
    defer game.deinit();
    try boot(&game, &.{.{ .name = "condenser", .src =
        \\{ "components": { "Overlay": { "fps": 6.0 } } }
    }});

    const e = game.spawnPrefab("condenser", .{ .x = 0, .y = 0 }).?;

    // Brand-new prefab: insert path, no instances, no refresh, no crash.
    try game.reloadPrefabSource("brand_new",
        \\{ "components": { "Overlay": { "fps": 1.0 } } }
    );
    try testing.expectEqual(@as(f32, 6.0), game.ecs_backend.getComponent(e, Overlay).?.fps);

    // Malformed source: transactional — registry AND instances stay.
    try testing.expectError(error.InvalidFormat, game.reloadPrefabSource("condenser", "{ \"components\": "));
    try testing.expectEqual(@as(f32, 6.0), game.ecs_backend.getComponent(e, Overlay).?.fps);
}
