//! Unknown components with entity-bearing arrays must not spawn ghost
//! entities (#808).
//!
//! `applyComponent` no-ops an unknown component (RFC #596 Axis 4), so
//! entities nested in its arrays have no field to patch their ids into.
//! Before the fix `spawnAndLinkNestedEntities` spawned and tracked them
//! anyway — real scene entities under a component that was never added.
//! These tests pin that the loader skips the unknown component's arrays
//! BEFORE spawning (scene-entity count unchanged, no `ChildrenComponent`
//! on the parent) and that the skip path fired its diagnostic
//! (`unknown-component-nested:<name>`, probed via `alreadyWarnedKey`).
//!
//! Component names are unique per test: the warn-once dedup set is
//! process-lifetime and never resets within a binary.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const core = @import("labelle-core");
const uf = engine.unified_format;

const Room = struct {
    workstations: []const u64 = &.{},
};

const Desk = struct {
    size: u32 = 1,
};

const Components = engine.ComponentRegistry(.{
    .industry__Room = Room,
    .Desk = Desk,
});

const Game = engine.Game;
const Bridge = engine.JsoncSceneBridge(Game, Components);
const ChildrenComp = core.ChildrenComponent(Game.EntityType);

const Fixture = struct {
    tmp_dir: testing.TmpDir,
    prefab_path: []u8,

    fn init(prefabs: []const struct { []const u8, []const u8 }) !Fixture {
        var tmp_dir = testing.tmpDir(.{});
        errdefer tmp_dir.cleanup();
        try tmp_dir.dir.createDir(std.testing.io, "prefabs", .default_dir);
        for (prefabs) |p| {
            try tmp_dir.dir.writeFile(std.testing.io, .{ .sub_path = p[0], .data = p[1] });
        }
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const len = try tmp_dir.dir.realPath(std.testing.io, &buf);
        const prefab_path = try std.fmt.allocPrint(testing.allocator, "{s}/prefabs", .{buf[0..len]});
        return .{ .tmp_dir = tmp_dir, .prefab_path = prefab_path };
    }

    fn deinit(self: *Fixture) void {
        testing.allocator.free(self.prefab_path);
        self.tmp_dir.cleanup();
    }
};

fn sceneEntityCount(game: *Game) usize {
    return game.scene_entities.items.len;
}

fn countWith(game: *Game, comptime T: type) usize {
    var n: usize = 0;
    var view = game.ecs_backend.view(.{T}, .{});
    defer view.deinit();
    while (view.next()) |_| n += 1;
    return n;
}

test "control: a REGISTERED component's entity array spawns and links (#808)" {
    var fx = try Fixture.init(&.{});
    defer fx.deinit();
    var game = Game.init(testing.allocator);
    defer game.deinit();
    try Bridge.loadSceneFromSource(&game,
        \\{ "children": [
        \\  { "components": { "industry__Room": { "workstations": [
        \\    { "components": { "Desk": { "size": 3 } } }
        \\  ] } } }
        \\] }
    , fx.prefab_path);
    // Parent + one nested workstation.
    try testing.expectEqual(@as(usize, 2), sceneEntityCount(&game));
    try testing.expectEqual(@as(usize, 1), countWith(&game, Desk));
    try testing.expectEqual(@as(usize, 1), countWith(&game, ChildrenComp));
    try testing.expect(!uf.alreadyWarnedKey("unknown-component-nested:industry__Room"));
}

test "typo'd namespaced component (components map) spawns no ghost entities (#808)" {
    var fx = try Fixture.init(&.{});
    defer fx.deinit();
    var game = Game.init(testing.allocator);
    defer game.deinit();
    try Bridge.loadSceneFromSource(&game,
        \\{ "children": [
        \\  { "components": { "industry__Romm808a": { "workstations": [
        \\    { "components": { "Desk": { "size": 3 } } },
        \\    { "components": { "Desk": { "size": 4 } } }
        \\  ] } } }
        \\] }
    , fx.prefab_path);
    // Only the parent entity exists; the nested entities never spawned.
    try testing.expectEqual(@as(usize, 1), sceneEntityCount(&game));
    try testing.expectEqual(@as(usize, 0), countWith(&game, Desk));
    try testing.expectEqual(@as(usize, 0), countWith(&game, ChildrenComp));
    // Diagnosed on both channels: the unknown component and the skip.
    try testing.expect(uf.alreadyWarnedKey("unknown-component:industry__Romm808a"));
    try testing.expect(uf.alreadyWarnedKey("unknown-component-nested:industry__Romm808a"));
}

test "flat unknown PascalCase component in a PREFAB spawns no ghosts (#808)" {
    var fx = try Fixture.init(&.{
        .{
            "prefabs/room808.jsonc",
            \\{ "Romm808b": { "workstations": [
            \\  { "components": { "Desk": { "size": 1 } } }
            \\] } }
        },
    });
    defer fx.deinit();
    var game = Game.init(testing.allocator);
    defer game.deinit();
    try Bridge.loadSceneFromSource(&game,
        \\{ "children": [ { "prefab": "room808" } ] }
    , fx.prefab_path);
    try testing.expectEqual(@as(usize, 1), sceneEntityCount(&game));
    try testing.expectEqual(@as(usize, 0), countWith(&game, Desk));
    try testing.expect(uf.alreadyWarnedKey("unknown-component:Romm808b"));
    try testing.expect(uf.alreadyWarnedKey("unknown-component-nested:Romm808b"));
}

test "unknown component on a NESTED entity spawns no deeper ghosts (#808)" {
    var fx = try Fixture.init(&.{});
    defer fx.deinit();
    var game = Game.init(testing.allocator);
    defer game.deinit();
    try Bridge.loadSceneFromSource(&game,
        \\{ "children": [
        \\  { "components": { "industry__Room": { "workstations": [
        \\    { "components": { "Desk": { "size": 2 }, "industry__Romm808c": { "slots": [
        \\      { "components": { "Desk": { "size": 9 } } }
        \\    ] } } }
        \\  ] } } }
        \\] }
    , fx.prefab_path);
    // Parent + the registered workstation; the typo'd grandchild never spawned.
    try testing.expectEqual(@as(usize, 2), sceneEntityCount(&game));
    try testing.expectEqual(@as(usize, 1), countWith(&game, Desk));
    try testing.expect(uf.alreadyWarnedKey("unknown-component-nested:industry__Romm808c"));
}

test "unknown component WITHOUT entity arrays does not raise the nested diagnostic (#808)" {
    var fx = try Fixture.init(&.{});
    defer fx.deinit();
    var game = Game.init(testing.allocator);
    defer game.deinit();
    try Bridge.loadSceneFromSource(&game,
        \\{ "children": [
        \\  { "components": { "Romm808d": { "tags": [1, 2, 3] } } }
        \\] }
    , fx.prefab_path);
    try testing.expectEqual(@as(usize, 1), sceneEntityCount(&game));
    try testing.expect(uf.alreadyWarnedKey("unknown-component:Romm808d"));
    try testing.expect(!uf.alreadyWarnedKey("unknown-component-nested:Romm808d"));
}

test "a §B2-malformed entry under an unknown component is still a load error (#808)" {
    // Skipping the unknown component's arrays must not skip the RFC #560
    // §B2 format gate: `{prefab + children}` fails loudly either way.
    var fx = try Fixture.init(&.{
        .{
            "prefabs/item808.jsonc",
            \\{ "Desk": { "size": 1 } }
        },
    });
    defer fx.deinit();
    var game = Game.init(testing.allocator);
    defer game.deinit();
    try testing.expectError(error.InvalidFormat, Bridge.loadSceneFromSource(&game,
        \\{ "children": [
        \\  { "components": { "Romm808e": { "items": [
        \\    { "prefab": "item808", "children": [ { "components": { "Desk": {} } } ] }
        \\  ] } } }
        \\] }
    , fx.prefab_path));
    try testing.expect(!uf.alreadyWarnedKey("unknown-component-nested:Romm808e"));
}
