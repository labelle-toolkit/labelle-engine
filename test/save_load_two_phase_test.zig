//! Save/load Slice 3 — two-phase load integration tests.
//!
//! Phase 1 re-spawns prefab-sourced entities via `spawnFromPrefab`
//! and maps their saved child IDs to the freshly-spawned entities by
//! walking `(root, local_path)`. Phase 2 then applies saved component
//! data on top. The payoff: non-saveable components (Sprite, animation
//! overlays, etc.) reappear on load without any game-side
//! re-hydration scripts.
//!
//! These tests scaffold a `JsoncSceneBridge` + a prefab jsonc on disk
//! + a TestGame with a real `ComponentRegistry`, spawn a prefab with
//! children, save, reset, load, and assert:
//!
//! - The prefab root is a freshly-spawned entity (not the saved id).
//! - Its children are the ones the prefab produced (matched via
//!   `PrefabChild.local_path`), not newly-created blank entities.
//! - Saved registered-component values are preserved on both root
//!   and children (Phase 2 overrides applied on top of Phase 1
//!   defaults).
//! - Non-prefab entities in the same save file still load through
//!   the v2 path unchanged.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const core = @import("labelle-core");

const Health = struct {
    pub const save = core.Saveable(.saveable, @This(), .{});
    current: f32 = 100,
    max: f32 = 100,
};

const TestComponents = engine.ComponentRegistry(.{
    .Health = Health,
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
const PrefabInstance = TestGame.PrefabInstanceComp;
const PrefabChild = TestGame.PrefabChildComp;

const TestFixture = struct {
    game: TestGame,
    prefab_dir: []const u8,

    fn deinit(self: *TestFixture) void {
        self.game.deinit();
        testing.allocator.free(self.prefab_dir);
    }
};

fn setupFixture(
    tmp_dir: *std.testing.TmpDir,
    prefab_files: anytype,
) !TestFixture {
    try tmp_dir.dir.createDir(std.testing.io, "prefabs", .default_dir);

    inline for (std.meta.fields(@TypeOf(prefab_files))) |field| {
        const path = try std.fmt.allocPrint(testing.allocator, "prefabs/{s}.jsonc", .{field.name});
        defer testing.allocator.free(path);
        try tmp_dir.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = @field(prefab_files, field.name) });
    }

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const _len = try tmp_dir.dir.realPath(std.testing.io, &buf);
    const dir_path = buf[0.._len];
    const prefab_dir = try std.fmt.allocPrint(testing.allocator, "{s}/prefabs", .{dir_path});
    errdefer testing.allocator.free(prefab_dir);

    var game = TestGame.init(testing.allocator);
    errdefer game.deinit();

    // Empty scene boot — we'll spawn prefabs manually via the runtime API.
    try Bridge.loadSceneFromSource(&game,
        \\{ "entities": [] }
    , prefab_dir);

    return .{ .game = game, .prefab_dir = prefab_dir };
}

test "two-phase load: prefab root + children re-spawn, saved state applies on top" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Prefab with one child. Both root and child carry Health so we
    // can verify Phase 2 overrides on each.
    var fixture = try setupFixture(&tmp_dir, .{
        .unit =
        \\{
        \\  "components": { "Health": { "current": 50, "max": 50 } },
        \\  "children": [
        \\    { "components": { "Health": { "current": 10, "max": 10 } } }
        \\  ]
        \\}
        ,
    });
    defer fixture.deinit();

    // Spawn. Mutate the saved Health to non-default values so we can
    // distinguish "loaded from save" from "re-spawned from prefab."
    const root = fixture.game.spawnFromPrefab("unit", .{ .x = 100, .y = 200 }).?;
    const root_h = fixture.game.active_world.ecs_backend.getComponent(root, Health).?;
    root_h.current = 33;

    const pre_children = fixture.game.getChildren(root);
    try testing.expectEqual(@as(usize, 1), pre_children.len);
    const child = pre_children[0];
    const child_h = fixture.game.active_world.ecs_backend.getComponent(child, Health).?;
    child_h.current = 7;

    // Save.
    const save_path = "test_save_two_phase.json";
    try fixture.game.saveGameState(save_path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, save_path) catch {};

    // Reset + load. Phase 1 should spawn the prefab, Phase 2 should
    // apply the mutated Health values we saved.
    fixture.game.resetEcsBackend();
    try fixture.game.loadGameState(save_path);

    // Exactly one PrefabInstance entity — the root. It should NOT be
    // the saved ID (we reset the ECS) and should carry the mutated
    // Health value from the save.
    var root_count: usize = 0;
    var loaded_root: TestGame.EntityType = 0;
    {
        var view = fixture.game.active_world.ecs_backend.view(.{PrefabInstance}, .{});
        while (view.next()) |ent| {
            root_count += 1;
            loaded_root = ent;
        }
        view.deinit();
    }
    try testing.expectEqual(@as(usize, 1), root_count);

    // Root has the mutated Health (overrides applied on top).
    const loaded_root_h = fixture.game.active_world.ecs_backend.getComponent(loaded_root, Health).?;
    try testing.expectApproxEqAbs(@as(f32, 33), loaded_root_h.current, 0.01);

    // The child came back via prefab re-spawn, not a fresh blank
    // entity. `getChildren` should give us exactly one child with
    // the mutated saved Health value.
    const loaded_children = fixture.game.getChildren(loaded_root);
    try testing.expectEqual(@as(usize, 1), loaded_children.len);
    const loaded_child_h = fixture.game.active_world.ecs_backend.getComponent(loaded_children[0], Health).?;
    try testing.expectApproxEqAbs(@as(f32, 7), loaded_child_h.current, 0.01);

    // The child must carry the `PrefabChild` tag (restored through
    // the save file). A fresh `createEntity` wouldn't have it.
    try testing.expect(fixture.game.active_world.ecs_backend.hasComponent(loaded_children[0], PrefabChild));
}

test "two-phase load: no duplicate entities — saved children map to spawned children" {
    // Phase 1 mustn't create BOTH the prefab-spawned child AND a
    // fresh blank entity for the saved PrefabChild. Regression guard
    // for the accidentally-dup-children failure mode.
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var fixture = try setupFixture(&tmp_dir, .{
        .three_kids =
        \\{
        \\  "components": { "Health": { "current": 100, "max": 100 } },
        \\  "children": [
        \\    { "components": { "Health": { "current": 1, "max": 1 } } },
        \\    { "components": { "Health": { "current": 2, "max": 2 } } },
        \\    { "components": { "Health": { "current": 3, "max": 3 } } }
        \\  ]
        \\}
        ,
    });
    defer fixture.deinit();

    _ = fixture.game.spawnFromPrefab("three_kids", .{ .x = 0, .y = 0 }).?;

    const save_path = "test_save_no_dup.json";
    try fixture.game.saveGameState(save_path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, save_path) catch {};

    fixture.game.resetEcsBackend();
    try fixture.game.loadGameState(save_path);

    // Total Health-carrying entities = 4 (1 root + 3 children), same
    // as before save. No duplicates.
    var count: usize = 0;
    var view = fixture.game.active_world.ecs_backend.view(.{Health}, .{});
    defer view.deinit();
    while (view.next()) |_| count += 1;
    try testing.expectEqual(@as(usize, 4), count);
}

test "two-phase load: non-prefab entities still load through v2 path" {
    // Phase 1c falls back to `createEntity` for entities without
    // `PrefabInstance` / `PrefabChild`. Regression guard that
    // intermixing prefab-sourced and plain entities in the same
    // save file still works.
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var fixture = try setupFixture(&tmp_dir, .{
        .prefab_thing =
        \\{ "components": { "Health": { "current": 50, "max": 50 } } }
        ,
    });
    defer fixture.deinit();

    // Spawn one via prefab, create one plain.
    _ = fixture.game.spawnFromPrefab("prefab_thing", .{ .x = 0, .y = 0 }).?;
    const plain = fixture.game.createEntity();
    fixture.game.active_world.ecs_backend.addComponent(plain, Health{ .current = 999, .max = 999 });

    const save_path = "test_save_mixed.json";
    try fixture.game.saveGameState(save_path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, save_path) catch {};

    fixture.game.resetEcsBackend();
    try fixture.game.loadGameState(save_path);

    // Both entities come back.
    var prefab_found = false;
    var plain_found = false;
    var view = fixture.game.active_world.ecs_backend.view(.{Health}, .{});
    defer view.deinit();
    while (view.next()) |ent| {
        const h = fixture.game.active_world.ecs_backend.getComponent(ent, Health).?;
        const has_pi = fixture.game.active_world.ecs_backend.hasComponent(ent, PrefabInstance);
        if (has_pi and @as(i32, @intFromFloat(h.current)) == 50) prefab_found = true;
        if (!has_pi and @as(i32, @intFromFloat(h.current)) == 999) plain_found = true;
    }
    try testing.expect(prefab_found);
    try testing.expect(plain_found);
}

test "two-phase load: scene-loaded prefab with children round-trips end-to-end" {
    // Integration exercising the real downstream path — scene jsonc
    // references a prefab by name, load does the instantiation +
    // tagging automatically, save writes both root and children
    // tags, load re-spawns and remaps. This is the flying-platform-
    // labelle scenario (decor rooms + their children).
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Write the prefab file.
    try tmp_dir.dir.createDir(std.testing.io, "prefabs", .default_dir);
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "prefabs/room.jsonc",
        .data =
        \\{
        \\  "components": { "Health": { "current": 100, "max": 100 } },
        \\  "children": [
        \\    { "components": { "Health": { "current": 11, "max": 11 } } },
        \\    { "components": { "Health": { "current": 22, "max": 22 } } }
        \\  ]
        \\}
        ,
    });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const _len = try tmp_dir.dir.realPath(std.testing.io, &buf);
    const dir_path = buf[0.._len];
    const prefab_dir = try std.fmt.allocPrint(testing.allocator, "{s}/prefabs", .{dir_path});
    defer testing.allocator.free(prefab_dir);

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try Bridge.loadSceneFromSource(&game,
        \\{
        \\  "entities": [
        \\    { "prefab": "room" }
        \\  ]
        \\}
    , prefab_dir);

    // Before save: mutate child Health so we can detect Phase 2
    // overrides on load.
    const orig_root = blk: {
        var view = game.active_world.ecs_backend.view(.{PrefabInstance}, .{});
        defer view.deinit();
        break :blk view.next().?;
    };
    const orig_children = game.getChildren(orig_root);
    try testing.expectEqual(@as(usize, 2), orig_children.len);
    game.active_world.ecs_backend.getComponent(orig_children[0], Health).?.current = 88;
    game.active_world.ecs_backend.getComponent(orig_children[1], Health).?.current = 77;

    // Save + reset + load.
    const save_path = "test_save_scene_e2e.json";
    try game.saveGameState(save_path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, save_path) catch {};

    game.resetEcsBackend();
    try game.loadGameState(save_path);

    // Exactly one PrefabInstance-tagged root came back.
    var loaded_root: TestGame.EntityType = 0;
    {
        var root_count: usize = 0;
        var view = game.active_world.ecs_backend.view(.{PrefabInstance}, .{});
        defer view.deinit();
        while (view.next()) |ent| {
            root_count += 1;
            loaded_root = ent;
        }
        try testing.expectEqual(@as(usize, 1), root_count);
    }

    // Two children, freshly respawned from the prefab, each carrying
    // the mutated saved Health (Phase 2 overrides on top of Phase 1
    // defaults).
    const loaded_children = game.getChildren(loaded_root);
    try testing.expectEqual(@as(usize, 2), loaded_children.len);
    try testing.expectApproxEqAbs(
        @as(f32, 88),
        game.active_world.ecs_backend.getComponent(loaded_children[0], Health).?.current,
        0.01,
    );
    try testing.expectApproxEqAbs(
        @as(f32, 77),
        game.active_world.ecs_backend.getComponent(loaded_children[1], Health).?.current,
        0.01,
    );

    // Both children carry PrefabChild tags pointing at the new root.
    const root_id: u32 = @intCast(loaded_root);
    for (loaded_children) |child| {
        const pc = game.active_world.ecs_backend.getComponent(child, PrefabChild).?;
        try testing.expectEqual(root_id, @as(u32, @intCast(pc.root)));
    }

    // Total Health-carrying entities: 1 root + 2 children = 3. No
    // duplicates.
    var total: usize = 0;
    var view = game.active_world.ecs_backend.view(.{Health}, .{});
    defer view.deinit();
    while (view.next()) |_| total += 1;
    try testing.expectEqual(@as(usize, 3), total);
}

test "two-phase load: spawnFromPrefab failure falls back to v2 createEntity" {
    // The save records a PrefabInstance with a prefab name that
    // doesn't exist in the current prefab cache (e.g. renamed
    // between save and load). Phase 1 logs a warning and skips the
    // entity; Phase 1c's v2 fallback creates it fresh so Phase 2 has
    // something to apply Health to. Saved Health value is preserved;
    // PrefabInstance tag is NOT restored (since spawnFromPrefab was
    // the source of truth for the path and it failed).
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var fixture = try setupFixture(&tmp_dir, .{
        .known =
        \\{ "components": { "Health": { "current": 100, "max": 100 } } }
        ,
    });
    defer fixture.deinit();

    // Spawn the known prefab, then hand-edit the save file to say a
    // different prefab name — simulating a renamed prefab.
    _ = fixture.game.spawnFromPrefab("known", .{ .x = 0, .y = 0 }).?;

    const save_path = "test_save_rename.json";
    try fixture.game.saveGameState(save_path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, save_path) catch {};

    // Read back, replace "known" with "missing", write back.
    const contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, save_path, testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(contents);
    const rewritten = try std.mem.replaceOwned(u8, testing.allocator, contents, "\"known\"", "\"missing\"");
    defer testing.allocator.free(rewritten);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = save_path, .data = rewritten });

    fixture.game.resetEcsBackend();
    try fixture.game.loadGameState(save_path);

    // An entity with Health must still exist post-load; Phase 1c
    // created it fresh when spawnFromPrefab("missing") failed.
    var count: usize = 0;
    var view = fixture.game.active_world.ecs_backend.view(.{Health}, .{});
    defer view.deinit();
    while (view.next()) |_| count += 1;
    try testing.expectEqual(@as(usize, 1), count);
}

test "two-phase load: nested prefab doesn't duplicate into a ghost root" {
    // Regression guard for the HIGH-severity bug gemini flagged on
    // #484: an entity that carries BOTH PrefabInstance and PrefabChild
    // (nested prefab — outer prefab has a child that is itself a
    // prefab) must NOT be respawned standalone by Phase 1a. Outer's
    // `spawnFromPrefab` reinstantiates the nested subtree; Phase 1b
    // then maps the inner root via `(outer_root, local_path)`.
    // Processing it in Phase 1a would create a duplicate "ghost"
    // root and leak the second subtree.
    //
    // The bug + fix span two branches:
    // - #484 added the Phase 1a skip-if-PrefabChild guard.
    // - #485 (this branch) tags scene-loaded prefab descendants so
    //   nested prefabs actually have BOTH tags after save/load — the
    //   scenario the guard protects against can now be exercised
    //   end-to-end, hence this test lives here.
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDir(std.testing.io, "prefabs", .default_dir);
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "prefabs/inner.jsonc",
        .data =
        \\{ "components": { "Health": { "current": 25, "max": 25 } } }
        ,
    });
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "prefabs/outer.jsonc",
        .data =
        \\{
        \\  "components": { "Health": { "current": 50, "max": 50 } },
        \\  "children": [
        \\    { "prefab": "inner" }
        \\  ]
        \\}
        ,
    });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const _len = try tmp_dir.dir.realPath(std.testing.io, &buf);
    const dir_path = buf[0.._len];
    const prefab_dir = try std.fmt.allocPrint(testing.allocator, "{s}/prefabs", .{dir_path});
    defer testing.allocator.free(prefab_dir);

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try Bridge.loadSceneFromSource(&game,
        \\{
        \\  "entities": [
        \\    { "prefab": "outer" }
        \\  ]
        \\}
    , prefab_dir);

    const save_path = "test_save_nested_prefab.json";
    try game.saveGameState(save_path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, save_path) catch {};

    game.resetEcsBackend();
    try game.loadGameState(save_path);

    // If Phase 1a processed the inner (carrying PrefabInstance +
    // PrefabChild) it would create a second "inner" root — a ghost.
    // Expect exactly one of each.
    var outer_count: usize = 0;
    var inner_count: usize = 0;
    var view = game.active_world.ecs_backend.view(.{PrefabInstance}, .{});
    defer view.deinit();
    while (view.next()) |ent| {
        const pi = game.active_world.ecs_backend.getComponent(ent, PrefabInstance).?;
        if (std.mem.eql(u8, pi.path, "outer")) outer_count += 1;
        if (std.mem.eql(u8, pi.path, "inner")) inner_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), outer_count);
    try testing.expectEqual(@as(usize, 1), inner_count);

    // Total Health-carrying entities = 2 (outer root + nested inner).
    // Ghost scenario would produce 3+ (second inner spawned standalone).
    var total: usize = 0;
    var h_view = game.active_world.ecs_backend.view(.{Health}, .{});
    defer h_view.deinit();
    while (h_view.next()) |_| total += 1;
    try testing.expectEqual(@as(usize, 2), total);
}

test "save: entities with only PrefabInstance are collected (no game-owned saveable)" {
    // Regression guard for the "pure visual prefab" gap flagged in
    // `Game.spawnFromPrefab`'s docstring and surfaced by the
    // flying-platform-labelle prefab-foundations adoption. A prefab
    // whose root has ONLY a `Sprite` + `PrefabInstance` (no
    // `.saveable` / `.marker` registered component) used to get
    // skipped by the save mixin's registry-driven collection pass,
    // silently miss from the save file, and vanish on load.
    //
    // The `saveGameState` collection step now auto-sweeps entities
    // with `PrefabInstance` / `PrefabChild` regardless of other
    // components, so the prefab survives round-trip and Phase 1
    // respawns it cleanly.

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Prefab that carries NO registered components — just Position
    // and PrefabInstance (auto-attached by `spawnFromPrefab`). The
    // entity exists in the world but the old collection step would
    // have missed it entirely.
    var fixture = try setupFixture(&tmp_dir, .{
        .pure_visual =
        \\{ "components": { "Position": { "x": 42, "y": 7 } } }
        ,
    });
    defer fixture.deinit();

    const spawned = fixture.game.spawnFromPrefab("pure_visual", .{ .x = 0, .y = 0 }).?;
    try testing.expect(fixture.game.ecs_backend.hasComponent(spawned, PrefabInstance));

    const save_path = try std.fmt.allocPrint(testing.allocator, "{s}/pure_visual.json", .{fixture.prefab_dir});
    defer testing.allocator.free(save_path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, save_path) catch {};
    try fixture.game.saveGameState(save_path);

    // The save file must mention the prefab — otherwise load can't
    // respawn it. Check by reading raw bytes: any serialisation of
    // `PrefabInstance.path = "pure_visual"` lands as a JSON string
    // containing the path name, and nothing else in the test
    // references that string.
    const save_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, save_path, testing.allocator, .limited(64 * 1024));
    defer testing.allocator.free(save_bytes);
    try testing.expect(std.mem.indexOf(u8, save_bytes, "\"pure_visual\"") != null);

    // Round-trip: reset and load. The entity should be back with
    // its PrefabInstance tag and the prefab-declared Position.
    fixture.game.resetEcsBackend();
    try fixture.game.loadGameState(save_path);

    var view = fixture.game.ecs_backend.view(.{PrefabInstance}, .{});
    defer view.deinit();
    var count: usize = 0;
    var restored_entity: TestGame.EntityType = 0;
    while (view.next()) |ent| {
        count += 1;
        restored_entity = ent;
    }
    try testing.expectEqual(@as(usize, 1), count);

    const pi = fixture.game.ecs_backend.getComponent(restored_entity, PrefabInstance).?;
    try testing.expectEqualStrings("pure_visual", pi.path);

    // Position is recovered (prefab default / saved override
    // precedence is pinned by other tests; this test's contract
    // is purely "did the entity survive the collection step at
    // all").
    _ = fixture.game.getPosition(restored_entity);
}

// ── #696: malformed / hostile save hardening ────────────────────────
//
// Saves are engine-written (trusted producer), so none of these fire in
// normal operation. The contract is a CLEAN failure — a returned error or
// a gracefully-skipped entry — instead of a `.integer`/`.object` tag-cast
// panic (debug) or memory corruption (release) on a corrupted / hand-edited
// file. These tests feed loadGameState hand-crafted bad JSON and assert it
// neither crashes nor misparses.

/// Write raw bytes to a save file under cwd and attempt to load them into a
/// bare TestGame. Returns whatever `loadGameState` returns (error or void).
fn tryLoadRaw(save_path: []const u8, bytes: []const u8) !void {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = save_path, .data = bytes });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, save_path) catch {};
    return game.loadGameState(save_path);
}

test "malformed save: non-object root → error.MalformedSave (no panic)" {
    // A save whose top-level value is an array would panic on the
    // `parsed.value.object` tag-cast before the fix.
    try testing.expectError(
        error.MalformedSave,
        tryLoadRaw("test_bad_root.json", "[]"),
    );
}

test "malformed save: wrong-typed version → error.MalformedSave (no panic)" {
    // `version` as a string would panic on `.integer` before the fix.
    try testing.expectError(
        error.MalformedSave,
        tryLoadRaw("test_bad_version.json",
            \\{ "version": "2", "entities": [] }
        ),
    );
}

test "malformed save: wrong-typed entities → error.MalformedSave (no panic)" {
    // `entities` as an object would panic on `.array` before the fix.
    try testing.expectError(
        error.MalformedSave,
        tryLoadRaw("test_bad_entities.json",
            \\{ "version": 2, "entities": {} }
        ),
    );
}

test "malformed save: non-integer entry id is skipped, not tag-cast (Step 4/5)" {
    // Steps 4 and 5 previously did `(obj.get("id").?).integer` directly —
    // a string `id` would panic there. With the shared `getSavedId` guard
    // the entry is skipped and the load completes with no entities.
    try tryLoadRaw("test_bad_id.json",
        \\{ "version": 2, "entities": [ { "id": "not-a-number", "components": {} } ] }
    );
}

test "malformed save: wrong-typed ref_arrays is skipped, not tag-cast (Step 4)" {
    // Step 4 previously did `ref_arrays_val.object` directly — a scalar
    // `ref_arrays` would panic. `getObjectField` skips it instead. The
    // entry has a valid integer id so it survives to Step 4.
    try tryLoadRaw("test_bad_refarrays.json",
        \\{ "version": 2, "entities": [ { "id": 0, "components": {}, "ref_arrays": 42 } ] }
    );
}

test "findChildByLocalPath: leading-dot separator is rejected (no misparse)" {
    // `PrefabChild.local_path` is emitted as `children[0]` (no leading
    // dot, single `.` between segments). A corrupted save carrying a
    // LEADING dot (`.children[0]`) used to resolve anyway — the old code
    // stripped the dot but never required its absence at the start. The
    // hardened walk rejects it, so Phase 1b can't map the child onto the
    // spawned prefab child; Phase 1c falls back to a fresh orphan entity.
    // The load must still complete cleanly (no crash), and the malformed
    // child override must NOT land on the prefab-spawned child.
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var fixture = try setupFixture(&tmp_dir, .{
        .unit =
        \\{
        \\  "components": { "Health": { "current": 50, "max": 50 } },
        \\  "children": [
        \\    { "components": { "Health": { "current": 10, "max": 10 } } }
        \\  ]
        \\}
        ,
    });
    defer fixture.deinit();

    const root = fixture.game.spawnFromPrefab("unit", .{ .x = 0, .y = 0 }).?;
    // Mutate the child so a correct mapping would apply Health 7 to the
    // spawned child; a rejected path leaves it at the prefab default (10).
    const child = fixture.game.getChildren(root)[0];
    fixture.game.active_world.ecs_backend.getComponent(child, Health).?.current = 7;

    const save_path = "test_bad_localpath.json";
    try fixture.game.saveGameState(save_path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, save_path) catch {};

    // Inject the malformed separator into the saved local_path.
    const contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, save_path, testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(contents);
    try testing.expect(std.mem.indexOf(u8, contents, "\"children[0]\"") != null);
    const rewritten = try std.mem.replaceOwned(u8, testing.allocator, contents, "\"children[0]\"", "\".children[0]\"");
    defer testing.allocator.free(rewritten);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = save_path, .data = rewritten });

    // Load must not crash / error.
    fixture.game.resetEcsBackend();
    try fixture.game.loadGameState(save_path);

    // The prefab-spawned child kept the prefab default (10) — the saved
    // override (7) was diverted to a fresh orphan, proving the malformed
    // path was rejected rather than silently resolved.
    const loaded_root = blk: {
        var view = fixture.game.active_world.ecs_backend.view(.{PrefabInstance}, .{});
        defer view.deinit();
        break :blk view.next().?;
    };
    const loaded_child = fixture.game.getChildren(loaded_root)[0];
    try testing.expectApproxEqAbs(
        @as(f32, 10),
        fixture.game.active_world.ecs_backend.getComponent(loaded_child, Health).?.current,
        0.01,
    );

    // 3 Health entities: root + spawned child (default) + orphan (override).
    var total: usize = 0;
    var view = fixture.game.active_world.ecs_backend.view(.{Health}, .{});
    defer view.deinit();
    while (view.next()) |_| total += 1;
    try testing.expectEqual(@as(usize, 3), total);
}

test "malformed save: non-object entity entry is skipped, valid siblings load" {
    // Every per-entry loop guards `entry != .object` through
    // `getComponentsObject` / `getSavedId` — before the fix Steps 4/5
    // tag-cast `entry.object` directly and a scalar entry panicked.
    // Per-entry corruption is skip-with-log (only header corruption is
    // fatal), so the valid sibling in the same file must still load.
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const save_path = "test_bad_entry_shape.json";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = save_path,
        .data =
        \\{ "version": 2, "entities": [
        \\  42,
        \\  { "id": 1, "components": { "Health": { "current": 5, "max": 5 } } }
        \\] }
        ,
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, save_path) catch {};

    try game.loadGameState(save_path);

    var count: usize = 0;
    var loaded_current: f32 = 0;
    var view = game.active_world.ecs_backend.view(.{Health}, .{});
    defer view.deinit();
    while (view.next()) |ent| {
        count += 1;
        loaded_current = game.active_world.ecs_backend.getComponent(ent, Health).?.current;
    }
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expectApproxEqAbs(@as(f32, 5), loaded_current, 0.01);
}

test "malformed save: negative id is skipped (no @intCast trap), valid siblings load" {
    // Steps 4/5 previously did `@intCast((obj.get("id") orelse continue)
    // .integer)` on the raw value — a negative saved id trapped the
    // u64 cast in debug builds. `getSavedId`/`getU64Field` clamp
    // negatives to null, so the entry is skipped end-to-end (Phase 1c
    // never maps it, Phase 2 never applies it) and the valid sibling
    // still loads.
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const save_path = "test_bad_negative_id.json";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = save_path,
        .data =
        \\{ "version": 2, "entities": [
        \\  { "id": -5, "components": { "Health": { "current": 1, "max": 1 } } },
        \\  { "id": 2, "components": { "Health": { "current": 9, "max": 9 } } }
        \\] }
        ,
    });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, save_path) catch {};

    try game.loadGameState(save_path);

    var count: usize = 0;
    var loaded_current: f32 = 0;
    var view = game.active_world.ecs_backend.view(.{Health}, .{});
    defer view.deinit();
    while (view.next()) |ent| {
        count += 1;
        loaded_current = game.active_world.ecs_backend.getComponent(ent, Health).?.current;
    }
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expectApproxEqAbs(@as(f32, 9), loaded_current, 0.01);
}

/// Shared body for the local_path separator cases (#696). Spawns a
/// three-level prefab (root → child → grandchild), mutates the
/// grandchild's Health to a sentinel (4), saves — the grandchild's
/// `PrefabChild.local_path` is emitted as `children[0].children[0]` —
/// optionally rewrites that path inside the save file, reloads, and
/// asserts where the sentinel landed:
///
///   * resolved path → Phase 1b maps the saved grandchild onto the
///     re-spawned one; it carries the sentinel; 3 Health entities total.
///   * rejected path → the walk returns null, Phase 1c diverts the saved
///     override to a fresh orphan; the re-spawned grandchild keeps the
///     prefab default (30); 4 Health entities total.
fn runLocalPathSeparatorCase(
    save_path: []const u8,
    rewrite_to: ?[]const u8,
    expected_grandchild_health: f32,
    expected_total: usize,
) !void {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var fixture = try setupFixture(&tmp_dir, .{
        .tower =
        \\{
        \\  "components": { "Health": { "current": 50, "max": 50 } },
        \\  "children": [
        \\    {
        \\      "components": { "Health": { "current": 40, "max": 40 } },
        \\      "children": [
        \\        { "components": { "Health": { "current": 30, "max": 30 } } }
        \\      ]
        \\    }
        \\  ]
        \\}
        ,
    });
    defer fixture.deinit();

    const root = fixture.game.spawnFromPrefab("tower", .{ .x = 0, .y = 0 }).?;
    const child = fixture.game.getChildren(root)[0];
    const grandchild = fixture.game.getChildren(child)[0];
    fixture.game.active_world.ecs_backend.getComponent(grandchild, Health).?.current = 4;

    try fixture.game.saveGameState(save_path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, save_path) catch {};

    // The grandchild's path must have been emitted in the two-segment
    // form — pins the emission format the strict walk parses
    // (`tagAsPrefabInstance`: `children[i]`, then `.children[j]`
    // appended). If the producer format ever drifts, this fails here
    // rather than silently testing a path the engine never writes.
    const contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, save_path, testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(contents);
    const needle = "\"children[0].children[0]\"";
    try testing.expect(std.mem.indexOf(u8, contents, needle) != null);

    if (rewrite_to) |bad_path| {
        const replacement = try std.fmt.allocPrint(testing.allocator, "\"{s}\"", .{bad_path});
        defer testing.allocator.free(replacement);
        const rewritten = try std.mem.replaceOwned(u8, testing.allocator, contents, needle, replacement);
        defer testing.allocator.free(rewritten);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = save_path, .data = rewritten });
    }

    // Load must complete cleanly in every case — a rejected path is a
    // skipped Phase 1b mapping, never an error.
    fixture.game.resetEcsBackend();
    try fixture.game.loadGameState(save_path);

    const loaded_root = blk: {
        var view = fixture.game.active_world.ecs_backend.view(.{PrefabInstance}, .{});
        defer view.deinit();
        break :blk view.next().?;
    };
    const loaded_child = fixture.game.getChildren(loaded_root)[0];
    const loaded_grandchild = fixture.game.getChildren(loaded_child)[0];
    try testing.expectApproxEqAbs(
        expected_grandchild_health,
        fixture.game.active_world.ecs_backend.getComponent(loaded_grandchild, Health).?.current,
        0.01,
    );

    var total: usize = 0;
    var view = fixture.game.active_world.ecs_backend.view(.{Health}, .{});
    defer view.deinit();
    while (view.next()) |_| total += 1;
    try testing.expectEqual(expected_total, total);
}

test "findChildByLocalPath: valid multi-segment children[0].children[0] still resolves" {
    // Positive control for the strict-separator walk: the exact format
    // `tagAsPrefabInstance` emits must keep resolving byte-for-byte. No
    // other test walks a two-segment path, so a regression in the
    // first-segment bookkeeping (e.g. demanding a dot before the first
    // segment, or not consuming the one before the second) would
    // otherwise ship silently.
    try runLocalPathSeparatorCase("test_localpath_valid.json", null, 4, 3);
}

test "findChildByLocalPath: missing separator children[0]children[0] is rejected" {
    // The old walk stripped a dot when present but never required one,
    // so this path resolved as if well-formed — aliasing the
    // grandchild's saved components onto the walked entity. The strict
    // walk rejects it: the override diverts to a fresh orphan and the
    // re-spawned grandchild keeps the prefab default.
    try runLocalPathSeparatorCase("test_localpath_nosep.json", "children[0]children[0]", 30, 4);
}

test "findChildByLocalPath: doubled separator children[0]..children[0] stays rejected" {
    // The pre-#696 walk already rejected doubled dots (it stripped at
    // most ONE dot, so the second broke the `children[` prefix match).
    // Pin that contract so the strict walk can't regress into absorbing
    // dot runs.
    try runLocalPathSeparatorCase("test_localpath_doubledot.json", "children[0]..children[0]", 30, 4);
}
