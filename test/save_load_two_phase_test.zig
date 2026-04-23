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
    try tmp_dir.dir.makeDir("prefabs");

    inline for (std.meta.fields(@TypeOf(prefab_files))) |field| {
        const path = try std.fmt.allocPrint(testing.allocator, "prefabs/{s}.jsonc", .{field.name});
        defer testing.allocator.free(path);
        try tmp_dir.dir.writeFile(.{ .sub_path = path, .data = @field(prefab_files, field.name) });
    }

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp_dir.dir.realpath(".", &buf);
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
    defer std.fs.cwd().deleteFile(save_path) catch {};

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
    defer std.fs.cwd().deleteFile(save_path) catch {};

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
    defer std.fs.cwd().deleteFile(save_path) catch {};

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
    try tmp_dir.dir.makeDir("prefabs");
    try tmp_dir.dir.writeFile(.{
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
    const dir_path = try tmp_dir.dir.realpath(".", &buf);
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
    defer std.fs.cwd().deleteFile(save_path) catch {};

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
    defer std.fs.cwd().deleteFile(save_path) catch {};

    // Read back, replace "known" with "missing", write back.
    const contents = try std.fs.cwd().readFileAlloc(testing.allocator, save_path, 1024 * 1024);
    defer testing.allocator.free(contents);
    const rewritten = try std.mem.replaceOwned(u8, testing.allocator, contents, "\"known\"", "\"missing\"");
    defer testing.allocator.free(rewritten);
    try std.fs.cwd().writeFile(.{ .sub_path = save_path, .data = rewritten });

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

    try tmp_dir.dir.makeDir("prefabs");
    try tmp_dir.dir.writeFile(.{
        .sub_path = "prefabs/inner.jsonc",
        .data =
        \\{ "components": { "Health": { "current": 25, "max": 25 } } }
        ,
    });
    try tmp_dir.dir.writeFile(.{
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
    const dir_path = try tmp_dir.dir.realpath(".", &buf);
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
    defer std.fs.cwd().deleteFile(save_path) catch {};

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

