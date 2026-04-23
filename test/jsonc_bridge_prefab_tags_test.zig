//! Slice 2b tests: `JsoncSceneBridge` auto-tags scene-loaded prefab
//! entities with `PrefabInstance` so the save mixin can reinstantiate
//! them on load without the game having to call `spawnFromPrefab`
//! manually.
//!
//! Scope covered here (root-only tagging; PrefabChild for scene-load
//! nested children is a follow-up — see the comment in
//! `loadEntityInternal` near the tagging call).

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
