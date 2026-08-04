//! Unknown-component diagnostics for namespaced keys (#803).
//!
//! `warnUnknownComponent` (RFC #596 Axis 4) fired only for PascalCase
//! names, so a typo'd pack-namespaced key — `industry__Storag` for
//! `industry__Storage` — silently no-op'd in every override path.
//! These tests pin the widened gate: namespaced-shaped unknowns warn,
//! data-shaped lowercase keys stay silent, and registered namespaced
//! components apply without warning.
//!
//! Warning observability: `uf.warnOnceKey` records fired keys in a
//! process-lifetime dedup set probed via `engine.unified_format
//! .alreadyWarnedKey` — no log capture needed. Component names are
//! unique per test because that set never resets within a binary.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const uf = engine.unified_format;

const Storage = struct {
    capacity: u32 = 5,
};

const Widget = struct {
    size: u32 = 1,
};

const Components = engine.ComponentRegistry(.{
    .industry__Storage = Storage,
    .industry__Widget806 = Widget,
});

const Game = engine.Game;
const Bridge = engine.JsoncSceneBridge(Game, Components);

fn loadScene(game: *Game, source: []const u8) !void {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDir(std.testing.io, "prefabs", .default_dir);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp_dir.dir.realPath(std.testing.io, &buf);
    const prefab_path = try std.fmt.allocPrint(testing.allocator, "{s}/prefabs", .{buf[0..len]});
    defer testing.allocator.free(prefab_path);
    try Bridge.loadSceneFromSource(game, source, prefab_path);
}

test "isComponentKeyShape: PascalCase and <prefix>__<Pascal> only" {
    try testing.expect(uf.isComponentKeyShape("Storage"));
    try testing.expect(uf.isComponentKeyShape("industry__Storage"));
    try testing.expect(uf.isComponentKeyShape("a__b__Pascal"));
    try testing.expect(!uf.isComponentKeyShape("capacity"));
    try testing.expect(!uf.isComponentKeyShape("capacity__oops"));
    try testing.expect(!uf.isComponentKeyShape("__Storage"));
    try testing.expect(!uf.isComponentKeyShape(""));
    try testing.expect(!uf.isComponentKeyShape("prefab"));
}

test "a typo'd namespaced component warns instead of silently no-opping (#803)" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    try loadScene(&game,
        \\{ "children": [
        \\  { "components": { "industry__Storag803": { "capacity": 12 } } }
        \\] }
    );
    // The scene loads (unknown components are no-ops, RFC #596) but
    // the diagnostic fired.
    try testing.expect(uf.alreadyWarnedKey("unknown-component:industry__Storag803"));
}

test "a registered namespaced component applies without warning" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    try loadScene(&game,
        \\{ "children": [
        \\  { "components": { "industry__Storage": { "capacity": 9 } } }
        \\] }
    );
    var view = game.ecs_backend.view(.{Storage}, .{});
    defer view.deinit();
    const e = view.next() orelse return error.TestExpectedEntity;
    try testing.expectEqual(@as(u32, 9), game.ecs_backend.getComponent(e, Storage).?.capacity);
    try testing.expect(!uf.alreadyWarnedKey("unknown-component:industry__Storage"));
}

test "a data-shaped lowercase key stays silent (not an authoring-mistake shape)" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    try loadScene(&game,
        \\{ "children": [
        \\  { "components": { "just_data_803": { "x": 1 } } }
        \\] }
    );
    try testing.expect(!uf.alreadyWarnedKey("unknown-component:just_data_803"));
}

test "flat-form typo'd namespaced key warns too (#806 round 1)" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    try loadScene(&game,
        \\{ "children": [
        \\  { "industry__Storag806": { "capacity": 12 } }
        \\] }
    );
    try testing.expect(uf.alreadyWarnedKey("unknown-component:industry__Storag806"));
}

test "flat-form REGISTERED namespaced components now apply (#806 round 1)" {
    // Before the isFlatComponentKey widening, a flat namespaced key
    // was silently dropped by synthesizeFlatComponents — a registered
    // pack component authored flat never attached.
    var game = Game.init(testing.allocator);
    defer game.deinit();
    try loadScene(&game,
        \\{ "children": [
        \\  { "industry__Storage": { "capacity": 21 } }
        \\] }
    );
    var view = game.ecs_backend.view(.{Storage}, .{});
    defer view.deinit();
    const e = view.next() orelse return error.TestExpectedEntity;
    try testing.expectEqual(@as(u32, 21), game.ecs_backend.getComponent(e, Storage).?.capacity);
}

test "a removal matching nothing warns; a legitimate removal stays silent" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDir(std.testing.io, "prefabs", .default_dir);
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "prefabs/crate806.jsonc",
        .data =
        \\{ "industry__Storage": { "capacity": 5 } }
        ,
    });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp_dir.dir.realPath(std.testing.io, &buf);
    const prefab_path = try std.fmt.allocPrint(testing.allocator, "{s}/prefabs", .{buf[0..len]});
    defer testing.allocator.free(prefab_path);

    var game = Game.init(testing.allocator);
    defer game.deinit();
    try Bridge.loadSceneFromSource(&game,
        \\{ "children": [
        \\  { "prefab": "crate806", "industry__Storage": null },
        \\  { "prefab": "crate806", "industry__Storag806b": null }
        \\] }
    , prefab_path);

    // Typo'd removal (matches nothing) → warned.
    try testing.expect(uf.alreadyWarnedKey("noop-removal:industry__Storag806b"));
    // Legitimate removal of a prefab-carried component → silent…
    try testing.expect(!uf.alreadyWarnedKey("noop-removal:industry__Storage"));
    // …and it actually removed on entity 1 while entity 2 kept it.
    var count: u32 = 0;
    var view = game.ecs_backend.view(.{Storage}, .{});
    defer view.deinit();
    while (view.next()) |_| count += 1;
    try testing.expectEqual(@as(u32, 1), count);
}

test "outer @ removal of an inner-@-added component is not a no-op warning (#806 round 2)" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDir(std.testing.io, "prefabs", .default_dir);
    // P: a machine-like prefab whose slot entity is ref-named.
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "prefabs/p806.jsonc",
        .data =
        \\{ "children": [ { "ref": "s806", "components": { "industry__Storage": { "capacity": 1 } } } ] }
        ,
    });
    // W: wrapper whose child reference ADDS Widget to @s806.
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "prefabs/w806.jsonc",
        .data =
        \\{ "children": [
        \\  { "prefab": "p806", "@s806": { "industry__Widget806": { "size": 7 } } }
        \\] }
        ,
    });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp_dir.dir.realPath(std.testing.io, &buf);
    const prefab_path = try std.fmt.allocPrint(testing.allocator, "{s}/prefabs", .{buf[0..len]});
    defer testing.allocator.free(prefab_path);

    var game = Game.init(testing.allocator);
    defer game.deinit();
    // Scene removes, at higher precedence, what the inner patch added.
    try Bridge.loadSceneFromSource(&game,
        \\{ "children": [
        \\  { "prefab": "w806", "@s806": { "industry__Widget806": null } }
        \\] }
    , prefab_path);

    // The removal matched a real (inner-added) component: no Widget
    // spawned, and NO false no-op warning.
    var view = game.ecs_backend.view(.{Widget}, .{});
    defer view.deinit();
    try testing.expect(view.next() == null);
    try testing.expect(!uf.alreadyWarnedKey("noop-removal:industry__Widget806"));
}

test "a lowercase data-shaped removal key stays outside the warning gate (#806 round 2)" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDir(std.testing.io, "prefabs", .default_dir);
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "prefabs/crate806c.jsonc",
        .data =
        \\{ "industry__Storage": { "capacity": 5 } }
        ,
    });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp_dir.dir.realPath(std.testing.io, &buf);
    const prefab_path = try std.fmt.allocPrint(testing.allocator, "{s}/prefabs", .{buf[0..len]});
    defer testing.allocator.free(prefab_path);

    var game = Game.init(testing.allocator);
    defer game.deinit();
    try Bridge.loadSceneFromSource(&game,
        \\{ "children": [
        \\  { "prefab": "crate806c", "some_data_806": null }
        \\] }
    , prefab_path);
    try testing.expect(!uf.alreadyWarnedKey("noop-removal:some_data_806"));
}

test "fan-out removal that lands on SOME matches is not a no-op (#806 round 3)" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDir(std.testing.io, "prefabs", .default_dir);
    // Two entities share the ref; only the first carries Storage.
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "prefabs/rack806.jsonc",
        .data =
        \\{ "children": [
        \\  { "ref": "cell806", "components": { "industry__Storage": { "capacity": 1 } } },
        \\  { "ref": "cell806", "components": { "industry__Widget806": { "size": 1 } } }
        \\] }
        ,
    });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp_dir.dir.realPath(std.testing.io, &buf);
    const prefab_path = try std.fmt.allocPrint(testing.allocator, "{s}/prefabs", .{buf[0..len]});
    defer testing.allocator.free(prefab_path);

    var game = Game.init(testing.allocator);
    defer game.deinit();
    try Bridge.loadSceneFromSource(&game,
        \\{ "children": [
        \\  { "prefab": "rack806", "@cell806": { "industry__Storage": null } }
        \\] }
    , prefab_path);

    // The removal landed on match #1 → no Storage anywhere, and NO
    // "matches nothing" warning despite match #2 lacking the component.
    var view = game.ecs_backend.view(.{Storage}, .{});
    defer view.deinit();
    try testing.expect(view.next() == null);
    try testing.expect(!uf.alreadyWarnedKey("noop-removal:industry__Storage"));
}

test "a @ removal landing on NO match warns once for the whole fan-out (#806 round 3)" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDir(std.testing.io, "prefabs", .default_dir);
    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "prefabs/rack806b.jsonc",
        .data =
        \\{ "children": [
        \\  { "ref": "cell806b", "components": { "industry__Widget806": { "size": 1 } } },
        \\  { "ref": "cell806b", "components": { "industry__Widget806": { "size": 2 } } }
        \\] }
        ,
    });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp_dir.dir.realPath(std.testing.io, &buf);
    const prefab_path = try std.fmt.allocPrint(testing.allocator, "{s}/prefabs", .{buf[0..len]});
    defer testing.allocator.free(prefab_path);

    var game = Game.init(testing.allocator);
    defer game.deinit();
    try Bridge.loadSceneFromSource(&game,
        \\{ "children": [
        \\  { "prefab": "rack806b", "@cell806b": { "industry__Storag806c": null } }
        \\] }
    , prefab_path);
    try testing.expect(uf.alreadyWarnedKey("noop-removal:industry__Storag806c"));
}
