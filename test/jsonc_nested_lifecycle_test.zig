/// Tests for nested-entity lifecycle hooks (onReady, postLoad) in the
/// JSONC scene bridge.
///
/// Regression coverage for the fix that made `spawnAndLinkNestedEntities`
/// fire `fireOnReadyAll` for nested children. Before the fix, only
/// top-level scene entities ran their `onReady`/`postLoad` hooks — any
/// component declared on a nested entity (e.g. inside a Room's
/// `workstations` array) silently skipped them.
///
/// A second regression covered here: the `applied` map passed into
/// `fireOnReadyAll` must be pre-populated with scene-component names,
/// or any component present in BOTH scene overrides and the prefab
/// would have its hooks fire twice (flagged by reviewers on the
/// original PR).

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const core = @import("labelle-core");

// ── Test components ────────────────────────────────────────────────
//
// `PostLoadBump` counts its own `postLoad` invocations via an instance
// field. Asserting on `bump.calls` per-entity keeps the test state
// entity-local and avoids global counters.

const PostLoadBump = struct {
    pub const save = core.Saveable(.saveable, @This(), .{});
    calls: u32 = 0,

    pub fn postLoad(self: *@This(), game: anytype, entity: anytype) void {
        _ = game;
        _ = entity;
        self.calls += 1;
    }
};

/// `OnReadyBump`'s hook is a static method — no instance to mutate. A
/// module-scope counter is reset at the start of each relevant test.
var on_ready_calls: u32 = 0;

const OnReadyBump = struct {
    _tag: u8 = 0,

    pub fn onReady(payload: engine.ComponentPayload) void {
        _ = payload;
        on_ready_calls += 1;
    }
};

/// Container that holds nested entities via a `slots` ref-array — the
/// same shape Workstation uses for `storages` in flying-platform.
const Container = struct {
    slots: []const u64 = &.{},
};

const Components = engine.ComponentRegistry(.{
    .PostLoadBump = PostLoadBump,
    .OnReadyBump = OnReadyBump,
    .Container = Container,
});

const Game = engine.Game;
const Bridge = engine.JsoncSceneBridge(Game, Components);

// ── Helpers ────────────────────────────────────────────────────────

fn tmpPath(tmp_dir: *std.testing.TmpDir, sub: []const u8) ![]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp_dir.dir.realpath(".", &buf);
    return std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir_path, sub });
}

fn loadSource(game: *Game, source: []const u8) !void {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makeDir("prefabs");
    const prefab_path = try tmpPath(&tmp_dir, "prefabs");
    defer testing.allocator.free(prefab_path);
    try Bridge.loadSceneFromSource(game, source, prefab_path);
}

// ── Tests ──────────────────────────────────────────────────────────

test "nested postLoad fires exactly once" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    try loadSource(&game,
        \\{
        \\  "entities": [
        \\    {
        \\      "components": {
        \\        "Container": {
        \\          "slots": [
        \\            { "components": { "PostLoadBump": {} } },
        \\            { "components": { "PostLoadBump": {} } }
        \\          ]
        \\        }
        \\      }
        \\    }
        \\  ]
        \\}
    );

    // Every nested entity with PostLoadBump should have calls == 1.
    // Pre-fix value would be 0 (postLoad never invoked on nested entities).
    var seen: u32 = 0;
    var view = game.ecs_backend.view(.{PostLoadBump}, .{});
    defer view.deinit();
    while (view.next()) |e| {
        const bump = game.ecs_backend.getComponent(e, PostLoadBump).?;
        try testing.expectEqual(@as(u32, 1), bump.calls);
        seen += 1;
    }
    try testing.expectEqual(@as(u32, 2), seen);
}

test "nested onReady fires exactly once per nested entity" {
    on_ready_calls = 0;

    var game = Game.init(testing.allocator);
    defer game.deinit();

    try loadSource(&game,
        \\{
        \\  "entities": [
        \\    {
        \\      "components": {
        \\        "Container": {
        \\          "slots": [
        \\            { "components": { "OnReadyBump": {} } },
        \\            { "components": { "OnReadyBump": {} } },
        \\            { "components": { "OnReadyBump": {} } }
        \\          ]
        \\        }
        \\      }
        \\    }
        \\  ]
        \\}
    );

    try testing.expectEqual(@as(u32, 3), on_ready_calls);
}

test "top-level postLoad still fires (regression guard)" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    try loadSource(&game,
        \\{
        \\  "entities": [
        \\    { "components": { "PostLoadBump": {} } }
        \\  ]
        \\}
    );

    var view = game.ecs_backend.view(.{PostLoadBump}, .{});
    defer view.deinit();
    const e = view.next() orelse return error.TestExpectedEntity;
    const bump = game.ecs_backend.getComponent(e, PostLoadBump).?;
    try testing.expectEqual(@as(u32, 1), bump.calls);
    try testing.expect(view.next() == null);
}

test "nested prefab-only postLoad fires exactly once" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makeDir("prefabs");

    try tmp_dir.dir.writeFile(.{
        .sub_path = "prefabs/slot.jsonc",
        .data =
        \\{
        \\  "components": {
        \\    "PostLoadBump": {}
        \\  }
        \\}
        ,
    });
    const scene_src =
        \\{
        \\  "entities": [
        \\    {
        \\      "components": {
        \\        "Container": {
        \\          "slots": [ { "prefab": "slot" } ]
        \\        }
        \\      }
        \\    }
        \\  ]
        \\}
    ;
    const prefab_path = try tmpPath(&tmp_dir, "prefabs");
    defer testing.allocator.free(prefab_path);

    var game = Game.init(testing.allocator);
    defer game.deinit();
    try Bridge.loadSceneFromSource(&game, scene_src, prefab_path);

    var view = game.ecs_backend.view(.{PostLoadBump}, .{});
    defer view.deinit();
    const e = view.next() orelse return error.TestExpectedEntity;
    const bump = game.ecs_backend.getComponent(e, PostLoadBump).?;
    try testing.expectEqual(@as(u32, 1), bump.calls);
}

test "nested scene override + prefab definition fires postLoad exactly once (no double-fire)" {
    // Regression for the bot-flagged second bug: if the `applied`
    // StringHashMap isn't seeded with scene-component names, the
    // prefab loop in `fireOnReadyAll` doesn't know a component was
    // already processed, so its hooks fire a second time.
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makeDir("prefabs");

    try tmp_dir.dir.writeFile(.{
        .sub_path = "prefabs/overridable.jsonc",
        .data =
        \\{
        \\  "components": {
        \\    "PostLoadBump": { "calls": 0 }
        \\  }
        \\}
        ,
    });
    const scene_src =
        \\{
        \\  "entities": [
        \\    {
        \\      "components": {
        \\        "Container": {
        \\          "slots": [
        \\            {
        \\              "prefab": "overridable",
        \\              "components": { "PostLoadBump": { "calls": 0 } }
        \\            }
        \\          ]
        \\        }
        \\      }
        \\    }
        \\  ]
        \\}
    ;
    const prefab_path = try tmpPath(&tmp_dir, "prefabs");
    defer testing.allocator.free(prefab_path);

    var game = Game.init(testing.allocator);
    defer game.deinit();
    try Bridge.loadSceneFromSource(&game, scene_src, prefab_path);

    var view = game.ecs_backend.view(.{PostLoadBump}, .{});
    defer view.deinit();
    const e = view.next() orelse return error.TestExpectedEntity;
    const bump = game.ecs_backend.getComponent(e, PostLoadBump).?;
    // Pre-seed-fix value would be 2 (scene loop + prefab loop).
    try testing.expectEqual(@as(u32, 1), bump.calls);
}

test "nested scene override + prefab definition fires onReady exactly once" {
    on_ready_calls = 0;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makeDir("prefabs");

    try tmp_dir.dir.writeFile(.{
        .sub_path = "prefabs/overridable_ready.jsonc",
        .data =
        \\{
        \\  "components": {
        \\    "OnReadyBump": {}
        \\  }
        \\}
        ,
    });
    const scene_src =
        \\{
        \\  "entities": [
        \\    {
        \\      "components": {
        \\        "Container": {
        \\          "slots": [
        \\            {
        \\              "prefab": "overridable_ready",
        \\              "components": { "OnReadyBump": {} }
        \\            }
        \\          ]
        \\        }
        \\      }
        \\    }
        \\  ]
        \\}
    ;
    const prefab_path = try tmpPath(&tmp_dir, "prefabs");
    defer testing.allocator.free(prefab_path);

    var game = Game.init(testing.allocator);
    defer game.deinit();
    try Bridge.loadSceneFromSource(&game, scene_src, prefab_path);

    try testing.expectEqual(@as(u32, 1), on_ready_calls);
}
