//! Slice 2b tests: `JsoncSceneBridge` auto-tags scene-loaded prefab
//! entities with `PrefabInstance` (root) + `PrefabChild` (each
//! prefab-declared descendant) so the save mixin can reinstantiate
//! them on load without the game having to call `spawnFromPrefab`
//! manually. Root tagging landed first in Slice 2b; descendant
//! tagging was completed in the Slice 2b+ follow-up that shares
//! the call site with the runtime `Game.tagAsPrefabInstance` helper.

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

// A Game configured with our `Health` in the component registry so
// the save mixin actually collects entities carrying it. The default
// `engine.Game` uses `EmptyComponents`, which means `saveGameState`
// would see zero entities — fine for jsonc-parse tests but not for
// save/load round-trip.
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
    scene_source: []const u8,
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

    try Bridge.loadSceneFromSource(&game, scene_source, prefab_dir);

    return .{ .game = game, .prefab_dir = prefab_dir };
}

test "jsonc_scene_bridge: prefab-sourced entity gets PrefabInstance tag" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var fixture = try setupFixture(&tmp_dir, .{
        .enemy =
        \\{
        \\  "components": { "Health": { "current": 75, "max": 100 } }
        \\}
        ,
    },
        \\{
        \\  "entities": [
        \\    { "prefab": "enemy", "components": { "Position": { "x": 10, "y": 20 } } }
        \\  ]
        \\}
    );
    defer fixture.deinit();

    var count: usize = 0;
    var view = fixture.game.active_world.ecs_backend.view(.{Health}, .{});
    defer view.deinit();
    while (view.next()) |ent| {
        count += 1;
        const pi = fixture.game.active_world.ecs_backend.getComponent(ent, PrefabInstance).?;
        try testing.expectEqualStrings("enemy", pi.path);
        try testing.expectEqualStrings("", pi.overrides);
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "jsonc_scene_bridge: non-prefab entity does NOT get PrefabInstance" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var fixture = try setupFixture(&tmp_dir, .{},
        \\{
        \\  "entities": [
        \\    { "components": { "Health": { "current": 50, "max": 50 } } }
        \\  ]
        \\}
    );
    defer fixture.deinit();

    var view = fixture.game.active_world.ecs_backend.view(.{Health}, .{});
    defer view.deinit();
    var count: usize = 0;
    while (view.next()) |ent| {
        count += 1;
        try testing.expect(!fixture.game.active_world.ecs_backend.hasComponent(ent, PrefabInstance));
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "jsonc_scene_bridge: multiple prefab instances each get their own PrefabInstance tag" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var fixture = try setupFixture(&tmp_dir, .{
        .warrior =
        \\{ "components": { "Health": { "current": 100, "max": 100 } } }
        ,
        .archer =
        \\{ "components": { "Health": { "current": 50, "max": 50 } } }
        ,
    },
        \\{
        \\  "entities": [
        \\    { "prefab": "warrior" },
        \\    { "prefab": "warrior", "components": { "Position": { "x": 5, "y": 5 } } },
        \\    { "prefab": "archer" }
        \\  ]
        \\}
    );
    defer fixture.deinit();

    var warrior_count: usize = 0;
    var archer_count: usize = 0;

    var view = fixture.game.active_world.ecs_backend.view(.{PrefabInstance}, .{});
    defer view.deinit();
    while (view.next()) |ent| {
        const pi = fixture.game.active_world.ecs_backend.getComponent(ent, PrefabInstance).?;
        if (std.mem.eql(u8, pi.path, "warrior")) warrior_count += 1;
        if (std.mem.eql(u8, pi.path, "archer")) archer_count += 1;
    }

    try testing.expectEqual(@as(usize, 2), warrior_count);
    try testing.expectEqual(@as(usize, 1), archer_count);
}

test "jsonc_scene_bridge: prefab children get PrefabChild tags on scene load" {
    // Scene-load counterpart to the runtime-spawn test in
    // `spawn_from_prefab_test.zig`. A prefab with nested children
    // declared via its own `"children"` array, referenced from the
    // scene by `"prefab"` name, should get its descendants tagged
    // with the same `local_path` format `spawnFromPrefab` uses —
    // otherwise the save mixin's two-phase load can't match saved
    // child IDs to newly-respawned children on F9.
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var fixture = try setupFixture(&tmp_dir, .{
        .tree =
        \\{
        \\  "components": { "Health": { "current": 100, "max": 100 } },
        \\  "children": [
        \\    { "components": { "Health": { "current": 10, "max": 10 } } },
        \\    {
        \\      "components": { "Health": { "current": 20, "max": 20 } },
        \\      "children": [
        \\        { "components": { "Health": { "current": 30, "max": 30 } } }
        \\      ]
        \\    }
        \\  ]
        \\}
        ,
    },
        \\{
        \\  "entities": [
        \\    { "prefab": "tree" }
        \\  ]
        \\}
    );
    defer fixture.deinit();

    // Find the root (carries PrefabInstance).
    var root: TestGame.EntityType = 0;
    {
        var view = fixture.game.active_world.ecs_backend.view(.{PrefabInstance}, .{});
        defer view.deinit();
        root = view.next().?;
    }

    // Three descendants: children[0], children[1], children[1].children[0].
    const PrefabChild = TestGame.PrefabChildComp;
    var found_c0 = false;
    var found_c1 = false;
    var found_c1_gc0 = false;
    var tagged_count: usize = 0;

    const root_id: u32 = @intCast(root);
    var view = fixture.game.active_world.ecs_backend.view(.{PrefabChild}, .{});
    defer view.deinit();
    while (view.next()) |ent| {
        tagged_count += 1;
        const pc = fixture.game.active_world.ecs_backend.getComponent(ent, PrefabChild).?;
        try testing.expectEqual(root_id, @as(u32, @intCast(pc.root)));
        if (std.mem.eql(u8, pc.local_path, "children[0]")) found_c0 = true;
        if (std.mem.eql(u8, pc.local_path, "children[1]")) found_c1 = true;
        if (std.mem.eql(u8, pc.local_path, "children[1].children[0]")) found_c1_gc0 = true;
    }

    try testing.expectEqual(@as(usize, 3), tagged_count);
    try testing.expect(found_c0);
    try testing.expect(found_c1);
    try testing.expect(found_c1_gc0);
}

test "jsonc_scene_bridge: scene-declared children on a prefab do NOT get PrefabChild" {
    // Regression guard for copilot L531/L608 on #485. A scene may
    // over-declare children on top of a prefab (e.g. the scene adds
    // decorations around a prefab-sourced room). Those scene-only
    // children must NOT be tagged with `PrefabChild`, because the
    // prefab definition doesn't own them — if the prefab later grows
    // a new child at the same `children[N]` slot, Phase 1b on load
    // would mis-map the saved scene-only child onto the new prefab
    // child.
    //
    // Fix: the scene bridge calls `tagAsPrefabInstance` BETWEEN the
    // prefab-declared children loop and the scene-declared children
    // loop, so only prefab-owned children are within reach of the
    // tagger's `getChildren` walk.
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var fixture = try setupFixture(&tmp_dir, .{
        // Prefab with one own child.
        .room =
        \\{
        \\  "components": { "Health": { "current": 100, "max": 100 } },
        \\  "children": [
        \\    { "components": { "Health": { "current": 50, "max": 50 } } }
        \\  ]
        \\}
        ,
    },
        // Scene adds TWO extra children on top of the prefab instance.
        \\{
        \\  "entities": [
        \\    {
        \\      "prefab": "room",
        \\      "children": [
        \\        { "components": { "Health": { "current": 10, "max": 10 } } },
        \\        { "components": { "Health": { "current": 20, "max": 20 } } }
        \\      ]
        \\    }
        \\  ]
        \\}
    );
    defer fixture.deinit();

    const PrefabChild = TestGame.PrefabChildComp;
    var tagged_count: usize = 0;
    var view = fixture.game.active_world.ecs_backend.view(.{PrefabChild}, .{});
    defer view.deinit();
    while (view.next()) |_| tagged_count += 1;

    // Only the single prefab-declared child should carry PrefabChild;
    // the two scene-added children must not.
    try testing.expectEqual(@as(usize, 1), tagged_count);
}

test "jsonc_scene_bridge: PrefabInstance.path survives save/load round-trip" {
    // End-to-end: scene-load tags → save → reset → load → tag restored.
    // This is the contract the save mixin's Slice 1b handlers build on,
    // and the reason the auto-tagging matters for downstream games.
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var fixture = try setupFixture(&tmp_dir, .{
        .unit =
        \\{ "components": { "Health": { "current": 30, "max": 30 } } }
        ,
    },
        \\{
        \\  "entities": [
        \\    { "prefab": "unit" }
        \\  ]
        \\}
    );
    defer fixture.deinit();

    const save_path = "test_save_bridge_prefab.json";
    try fixture.game.saveGameState(save_path);
    defer std.fs.cwd().deleteFile(save_path) catch {};

    const json = try std.fs.cwd().readFileAlloc(testing.allocator, save_path, 1024 * 1024);
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"PrefabInstance\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"path\": \"unit\"") != null);

    fixture.game.resetEcsBackend();
    try fixture.game.loadGameState(save_path);

    var view = fixture.game.active_world.ecs_backend.view(.{PrefabInstance}, .{});
    defer view.deinit();
    var count: usize = 0;
    while (view.next()) |ent| {
        count += 1;
        const pi = fixture.game.active_world.ecs_backend.getComponent(ent, PrefabInstance).?;
        try testing.expectEqualStrings("unit", pi.path);
    }
    try testing.expectEqual(@as(usize, 1), count);
}
