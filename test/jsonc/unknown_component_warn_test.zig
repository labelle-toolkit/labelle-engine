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

const Components = engine.ComponentRegistry(.{
    .industry__Storage = Storage,
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
