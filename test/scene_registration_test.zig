//! Startup scene registration (#922).
//!
//! The generated `main` registers every scene at startup, one call per
//! scene: `registerSceneSimple`, then `setSceneSource`, `setSceneAssets`
//! and `setSceneInitialState`, then `setScene(<initial>)`. #922 moved the
//! hash-map work of those calls into shared `noinline` helpers
//! (`putSceneEntry`, `sceneEntryPtr`) so ~140 per-scene instantiations no
//! longer inline into `main`. This file replays that startup sequence and
//! pins what it must keep doing:
//!   - every registered name dispatches to ITS OWN loader (the comptime
//!     loader is still wired through the per-scene wrapper);
//!   - the per-scene setters attach to the right entry, in call order, and
//!     a later call wins;
//!   - unknown names still fail with `error.SceneNotFound`;
//!   - re-registering a scene replaces its loader and keeps one entry.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const Game = engine.Game;

var loaded: [16][]const u8 = undefined;
var loaded_len: usize = 0;

fn record(name: []const u8) void {
    loaded[loaded_len] = name;
    loaded_len += 1;
}

fn loaderFor(comptime name: []const u8) fn (*Game) anyerror!void {
    return struct {
        fn load(_: *Game) anyerror!void {
            record(name);
        }
    }.load;
}

const scene_names = [_][]const u8{ "intro", "loading", "menu", "main", "debug/a", "debug/b/c" };
const sources = [_][]const u8{ "{\"i\":0}", "{\"i\":1}", "{\"i\":2}", "{\"i\":3}", "{\"i\":4}", "{\"i\":5}" };
const intro_assets = [_][]const u8{};
const main_assets = [_][]const u8{ "characters", "rooms" };

fn registerAll(game: *Game) void {
    inline for (scene_names) |name| game.registerSceneSimple(name, loaderFor(name));
}

test "startup registration: every scene dispatches to its own loader" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    loaded_len = 0;

    registerAll(&game);
    try testing.expectEqual(@as(u32, scene_names.len), game.scenes.count());

    // Load in a different order than registration: each name must reach
    // its own loader, not a neighbour's.
    const order = [_][]const u8{ "debug/b/c", "intro", "main", "debug/a", "menu", "loading" };
    for (order) |name| {
        const entry = game.scenes.get(name) orelse return error.TestExpectedScene;
        try entry.loader_fn(&game);
    }
    try testing.expectEqual(order.len, loaded_len);
    for (order, 0..) |name, i| try testing.expectEqualStrings(name, loaded[i]);
}

test "startup registration: per-scene setters attach to the right entry" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    registerAll(&game);
    for (scene_names, sources) |name, src| try game.setSceneSource(name, src);
    try game.setSceneAssets("intro", &intro_assets);
    try game.setSceneAssets("main", &main_assets);
    try game.setSceneInitialState("main", "playing");
    try game.setSceneInitialState("menu", "menu");

    for (scene_names, sources) |name, src| {
        const entry = game.scenes.get(name).?;
        try testing.expectEqualStrings(src, entry.source.?);
    }
    try testing.expectEqual(@as(usize, 2), game.scenes.get("main").?.assets.len);
    try testing.expectEqualStrings("rooms", game.scenes.get("main").?.assets[1]);
    try testing.expectEqual(@as(usize, 0), game.scenes.get("loading").?.assets.len);
    try testing.expectEqualStrings("playing", game.scenes.get("main").?.initial_state.?);
    try testing.expectEqualStrings("menu", game.scenes.get("menu").?.initial_state.?);
    try testing.expect(game.scenes.get("intro").?.initial_state == null);

    // A later call wins.
    try game.setSceneSource("main", "{}");
    try testing.expectEqualStrings("{}", game.scenes.get("main").?.source.?);

    // Unknown names still fail, for every setter.
    try testing.expectError(error.SceneNotFound, game.setSceneSource("nope", "{}"));
    try testing.expectError(error.SceneNotFound, game.setSceneAssets("nope", &main_assets));
    try testing.expectError(error.SceneNotFound, game.setSceneInitialState("nope", "x"));
}

test "startup registration: re-registering replaces the loader, one entry" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    loaded_len = 0;

    game.registerSceneSimple("intro", loaderFor("first"));
    game.registerSceneSimple("intro", loaderFor("second"));
    try testing.expectEqual(@as(u32, 1), game.scenes.count());
    try game.scenes.get("intro").?.loader_fn(&game);
    try testing.expectEqual(@as(usize, 1), loaded_len);
    try testing.expectEqualStrings("second", loaded[0]);
}

test "startup registration: setScene runs the initial scene's loader" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    loaded_len = 0;

    registerAll(&game);
    try game.setScene("intro");
    try testing.expectEqual(@as(usize, 1), loaded_len);
    try testing.expectEqualStrings("intro", loaded[0]);
    try testing.expectEqualStrings("intro", game.current_scene_name.?);
}
