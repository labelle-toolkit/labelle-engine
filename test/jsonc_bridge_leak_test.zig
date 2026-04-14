/// Regression tests for GPA memory leaks in JsoncSceneBridge.
/// Uses std.testing.allocator (GPA with leak detection) to catch:
///   - Scene Value tree internal allocations (parseObject/parseArray entries/items)
///   - Nested entity ID arrays from spawnAndLinkNestedEntities
///   - stripEntityArrayFields filtered entries slices
const std = @import("std");
const testing = std.testing;
const engine = @import("engine");

// ── Test component types ────────────────────────────────────────────

const Health = struct {
    current: f32 = 100,
    max: f32 = 100,
};

const Inventory = struct {
    slots: u32 = 10,
};

const Squad = struct {
    members: []const u64 = &.{},
};

const Components = engine.ComponentRegistry(.{
    .Health = Health,
    .Inventory = Inventory,
    .Squad = Squad,
});

const Bridge = engine.JsoncSceneBridge(engine.Game, Components);

// ── Helpers ─────────────────────────────────────────────────────────

fn tmpPath(tmp_dir: *std.testing.TmpDir, sub: []const u8) ![]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp_dir.dir.realpath(".", &buf);
    return std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir_path, sub });
}

// ── Leak regression tests ───────────────────────────────────────────

test "loadScene: simple scene with components does not leak" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(.{
        .sub_path = "scene.jsonc",
        .data =
        \\{
        \\  "entities": [
        \\    { "components": { "Position": { "x": 10, "y": 20 }, "Health": { "current": 50, "max": 100 } } },
        \\    { "components": { "Position": { "x": 30, "y": 40 }, "Inventory": { "slots": 5 } } }
        \\  ]
        \\}
        ,
    });
    try tmp_dir.dir.makeDir("prefabs");

    const scene_path = try tmpPath(&tmp_dir, "scene.jsonc");
    defer testing.allocator.free(scene_path);
    const prefab_path = try tmpPath(&tmp_dir, "prefabs");
    defer testing.allocator.free(prefab_path);

    var game = engine.Game.init(testing.allocator);
    defer game.deinit();

    try Bridge.loadScene(&game, scene_path, prefab_path);
}

test "loadSceneFromSource: simple scene with components does not leak" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makeDir("prefabs");
    const prefab_path = try tmpPath(&tmp_dir, "prefabs");
    defer testing.allocator.free(prefab_path);

    const source =
        \\{
        \\  "entities": [
        \\    { "components": { "Position": { "x": 10, "y": 20 }, "Health": { "current": 50, "max": 100 } } },
        \\    { "components": { "Position": { "x": 30, "y": 40 }, "Inventory": { "slots": 5 } } }
        \\  ]
        \\}
    ;

    var game = engine.Game.init(testing.allocator);
    defer game.deinit();

    try Bridge.loadSceneFromSource(&game, source, prefab_path);
}

test "loadScene: scene with prefabs does not leak" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makeDir("prefabs");
    try tmp_dir.dir.writeFile(.{
        .sub_path = "prefabs/enemy.jsonc",
        .data =
        \\{
        \\  "components": {
        \\    "Health": { "current": 30, "max": 30 },
        \\    "Position": { "x": 0, "y": 0 }
        \\  }
        \\}
        ,
    });

    try tmp_dir.dir.writeFile(.{
        .sub_path = "scene.jsonc",
        .data =
        \\{
        \\  "entities": [
        \\    { "prefab": "enemy", "components": { "Position": { "x": 100, "y": 200 } } },
        \\    { "prefab": "enemy", "components": { "Position": { "x": 300, "y": 400 } } },
        \\    { "prefab": "enemy" }
        \\  ]
        \\}
        ,
    });

    const scene_path = try tmpPath(&tmp_dir, "scene.jsonc");
    defer testing.allocator.free(scene_path);
    const prefab_path = try tmpPath(&tmp_dir, "prefabs");
    defer testing.allocator.free(prefab_path);

    var game = engine.Game.init(testing.allocator);
    defer game.deinit();

    try Bridge.loadScene(&game, scene_path, prefab_path);
}

test "loadScene: nested entity arrays (spawnAndLinkNestedEntities) do not leak" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makeDir("prefabs");

    // Scene with a Squad component containing nested entity array
    try tmp_dir.dir.writeFile(.{
        .sub_path = "scene.jsonc",
        .data =
        \\{
        \\  "entities": [
        \\    {
        \\      "components": {
        \\        "Position": { "x": 0, "y": 0 },
        \\        "Squad": {
        \\          "members": [
        \\            { "components": { "Position": { "x": 1, "y": 1 }, "Health": { "current": 10 } } },
        \\            { "components": { "Position": { "x": 2, "y": 2 }, "Health": { "current": 20 } } }
        \\          ]
        \\        }
        \\      }
        \\    }
        \\  ]
        \\}
        ,
    });

    const scene_path = try tmpPath(&tmp_dir, "scene.jsonc");
    defer testing.allocator.free(scene_path);
    const prefab_path = try tmpPath(&tmp_dir, "prefabs");
    defer testing.allocator.free(prefab_path);

    var game = engine.Game.init(testing.allocator);
    defer game.deinit();

    try Bridge.loadScene(&game, scene_path, prefab_path);
}

test "loadScene: children entities do not leak" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makeDir("prefabs");

    try tmp_dir.dir.writeFile(.{
        .sub_path = "scene.jsonc",
        .data =
        \\{
        \\  "entities": [
        \\    {
        \\      "components": { "Position": { "x": 0, "y": 0 } },
        \\      "children": [
        \\        { "components": { "Position": { "x": 10, "y": 0 }, "Health": { "current": 50 } } },
        \\        { "components": { "Position": { "x": 20, "y": 0 }, "Inventory": { "slots": 3 } } }
        \\      ]
        \\    }
        \\  ]
        \\}
        ,
    });

    const scene_path = try tmpPath(&tmp_dir, "scene.jsonc");
    defer testing.allocator.free(scene_path);
    const prefab_path = try tmpPath(&tmp_dir, "prefabs");
    defer testing.allocator.free(prefab_path);

    var game = engine.Game.init(testing.allocator);
    defer game.deinit();

    try Bridge.loadScene(&game, scene_path, prefab_path);
}

test "loadSceneFromSource: embedded prefabs are preserved across loadSceneFromSource" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makeDir("prefabs");
    const prefab_path = try tmpPath(&tmp_dir, "prefabs");
    defer testing.allocator.free(prefab_path);

    // Embedded prefab — intentionally not written to disk so file fallback cannot help.
    const prefab_source =
        \\{
        \\  "components": {
        \\    "Health": { "current": 42, "max": 100 },
        \\    "Position": { "x": 0, "y": 0 }
        \\  }
        \\}
    ;

    // Scene that references the embedded prefab by name.
    const scene_source =
        \\{
        \\  "entities": [
        \\    { "prefab": "hero", "components": { "Position": { "x": 10, "y": 20 } } }
        \\  ]
        \\}
    ;

    var game = engine.Game.init(testing.allocator);
    defer game.deinit();

    try Bridge.addEmbeddedPrefab(&game, "hero", prefab_source, prefab_path);
    try Bridge.loadSceneFromSource(&game, scene_source, prefab_path);

    // The entity must carry the Health component from the embedded prefab (current == 42).
    // If the cache was discarded by loadSceneFromSource the component would be absent.
    var found_health = false;
    {
        var view = game.ecs_backend.view(.{Health}, .{});
        while (view.next()) |e| {
            const h = game.ecs_backend.getComponent(e, Health).?;
            if (h.current == 42) found_health = true;
        }
        view.deinit();
    }
    try testing.expect(found_health);
}
