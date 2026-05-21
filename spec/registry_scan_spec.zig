//! zspec BDD specs for the eager filesystem registry scan
//! (RFC #560, ticket #561).
//!
//! `loadScene` (the desktop entry point) recursively scans the
//! project's `prefabs/` and sibling `scenes/` directories up-front,
//! populating the flat name-keyed registry. These specs cover the
//! behaviours that scan unlocks — none reachable through the embedded
//! `addEmbeddedPrefab` path the other specs use:
//!
//!  - a prefab resolved by a `"name"` that diverges from its filename,
//!  - a scene file found by the scan (recursively, in a subdirectory),
//!  - two files sharing an effective name → `error.DuplicatePrefabName`.
//!
//! Each example builds a throwaway project tree under `std.testing`'s
//! tmp dir so the scan has a real filesystem to walk.

const std = @import("std");
const zspec = @import("zspec");
const engine = @import("engine");
const core = @import("labelle-core");

const expect = zspec.expect;

// ── Components under test ───────────────────────────────────────────

const Marker = struct { id: i32 = 0 };

const Components = engine.ComponentRegistry(.{
    .Marker = Marker,
});

const Game = engine.Game;
const Bridge = engine.JsoncSceneBridge(Game, Components);

// ── Helpers ─────────────────────────────────────────────────────────

/// Absolute path to `sub` inside the tmp dir.
fn tmpPath(tmp_dir: *std.testing.TmpDir, sub: []const u8) ![]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp_dir.dir.realPath(std.testing.io, &buf);
    return std.fmt.allocPrint(zspec.allocator, "{s}/{s}", .{ buf[0..len], sub });
}

/// First entity carrying a `Marker` with the given id, or null.
fn findMarker(game: *Game, id: i32) ?*Marker {
    var view = game.ecs_backend.view(.{Marker}, .{});
    defer view.deinit();
    while (view.next()) |e| {
        const m = game.ecs_backend.getComponent(e, Marker).?;
        if (m.id == id) return m;
    }
    return null;
}

pub const RegistryScanSpec = struct {
    // ── prefab found by a divergent "name" ──────────────────────────

    pub const @"a prefab whose name diverges from its filename" = struct {
        var tmp_dir: std.testing.TmpDir = undefined;
        var game: Game = undefined;

        test "tests:before" {
            tmp_dir = std.testing.tmpDir(.{});
            try tmp_dir.dir.createDir(std.testing.io, "prefabs", .default_dir);
            try tmp_dir.dir.createDir(std.testing.io, "scenes", .default_dir);

            // File `widget.jsonc` declares a divergent effective name
            // `"super_widget"`. Lazy basename lookup would miss it;
            // only the eager scan keys it by its `"name"` field.
            try tmp_dir.dir.writeFile(std.testing.io, .{
                .sub_path = "prefabs/widget.jsonc",
                .data =
                \\{ "name": "super_widget",
                \\  "root": { "components": { "Marker": { "id": 42 } } } }
                ,
            });
            try tmp_dir.dir.writeFile(std.testing.io, .{
                .sub_path = "scenes/main.jsonc",
                .data =
                \\{ "root": { "children": [
                \\  { "prefab": "super_widget" }
                \\] } }
                ,
            });

            game = Game.init(zspec.allocator);
        }

        test "tests:after" {
            game.deinit();
            tmp_dir.cleanup();
        }

        test "the scene resolves the prefab by its \"name\" field" {
            const scene_path = try tmpPath(&tmp_dir, "scenes/main.jsonc");
            defer zspec.allocator.free(scene_path);
            const prefab_dir = try tmpPath(&tmp_dir, "prefabs");
            defer zspec.allocator.free(prefab_dir);
            try Bridge.loadScene(&game, scene_path, prefab_dir);

            // Prefab applied → entity carries Marker id 42.
            try expect.notToBeNull(findMarker(&game, 42));
        }
    };

    // ── scene found by the scan ─────────────────────────────────────

    pub const @"a scene file discovered by the recursive scan" = struct {
        var tmp_dir: std.testing.TmpDir = undefined;
        var game: Game = undefined;

        test "tests:before" {
            tmp_dir = std.testing.tmpDir(.{});
            try tmp_dir.dir.createDir(std.testing.io, "prefabs", .default_dir);
            try tmp_dir.dir.createDir(std.testing.io, "scenes", .default_dir);
            // A nested subdirectory exercises the recursive walk.
            try tmp_dir.dir.createDir(std.testing.io, "scenes/levels", .default_dir);

            try tmp_dir.dir.writeFile(std.testing.io, .{
                .sub_path = "scenes/levels/arena.jsonc",
                .data =
                \\{ "name": "arena_one",
                \\  "root": { "components": { "Marker": { "id": 7 } } } }
                ,
            });
            // The scene we actually load. It references `arena_one`
            // by effective name — a file that lives only under
            // `scenes/levels/`, so resolving it proves the recursive
            // scan walked the `scenes/` tree and registered it.
            try tmp_dir.dir.writeFile(std.testing.io, .{
                .sub_path = "scenes/boot.jsonc",
                .data =
                \\{ "root": { "children": [
                \\  { "prefab": "arena_one" }
                \\] } }
                ,
            });

            game = Game.init(zspec.allocator);
        }

        test "tests:after" {
            game.deinit();
            tmp_dir.cleanup();
        }

        test "the nested scene is registered under its effective name" {
            const scene_path = try tmpPath(&tmp_dir, "scenes/boot.jsonc");
            defer zspec.allocator.free(scene_path);
            const prefab_dir = try tmpPath(&tmp_dir, "prefabs");
            defer zspec.allocator.free(prefab_dir);
            try Bridge.loadScene(&game, scene_path, prefab_dir);

            // `boot.jsonc` referenced `arena_one`, a file living only
            // under `scenes/levels/`. Resolving it (Marker id 7
            // applied) proves the scan walked `scenes/` recursively
            // and keyed it by its `"name"`.
            try expect.notToBeNull(findMarker(&game, 7));
        }
    };

    // ── effective-name collision ────────────────────────────────────

    pub const @"two files sharing an effective name" = struct {
        var tmp_dir: std.testing.TmpDir = undefined;
        var game: Game = undefined;

        test "tests:before" {
            tmp_dir = std.testing.tmpDir(.{});
            try tmp_dir.dir.createDir(std.testing.io, "prefabs", .default_dir);
            try tmp_dir.dir.createDir(std.testing.io, "scenes", .default_dir);

            // Two prefab files collide: `box.jsonc` keyed by its
            // basename `box`, and `crate.jsonc` whose `"name"` field
            // is also `"box"`.
            try tmp_dir.dir.writeFile(std.testing.io, .{
                .sub_path = "prefabs/box.jsonc",
                .data =
                \\{ "root": { "components": { "Marker": { "id": 1 } } } }
                ,
            });
            try tmp_dir.dir.writeFile(std.testing.io, .{
                .sub_path = "prefabs/crate.jsonc",
                .data =
                \\{ "name": "box",
                \\  "root": { "components": { "Marker": { "id": 2 } } } }
                ,
            });
            try tmp_dir.dir.writeFile(std.testing.io, .{
                .sub_path = "scenes/main.jsonc",
                .data =
                \\{ "root": { "children": [] } }
                ,
            });

            game = Game.init(zspec.allocator);
        }

        test "tests:after" {
            game.deinit();
            tmp_dir.cleanup();
        }

        test "the scan raises error.DuplicatePrefabName" {
            const scene_path = try tmpPath(&tmp_dir, "scenes/main.jsonc");
            defer zspec.allocator.free(scene_path);
            const prefab_dir = try tmpPath(&tmp_dir, "prefabs");
            defer zspec.allocator.free(prefab_dir);
            const result = Bridge.loadScene(&game, scene_path, prefab_dir);
            try std.testing.expectError(error.DuplicatePrefabName, result);
        }
    };

    // ── idempotent scan across a scene reload ───────────────────────

    pub const @"loadScene called twice on the same game" = struct {
        var tmp_dir: std.testing.TmpDir = undefined;
        var game: Game = undefined;

        test "tests:before" {
            tmp_dir = std.testing.tmpDir(.{});
            try tmp_dir.dir.createDir(std.testing.io, "prefabs", .default_dir);
            try tmp_dir.dir.createDir(std.testing.io, "scenes", .default_dir);

            try tmp_dir.dir.writeFile(std.testing.io, .{
                .sub_path = "prefabs/widget.jsonc",
                .data =
                \\{ "name": "super_widget",
                \\  "root": { "components": { "Marker": { "id": 99 } } } }
                ,
            });
            try tmp_dir.dir.writeFile(std.testing.io, .{
                .sub_path = "scenes/main.jsonc",
                .data =
                \\{ "root": { "children": [
                \\  { "prefab": "super_widget" }
                \\] } }
                ,
            });

            game = Game.init(zspec.allocator);
        }

        test "tests:after" {
            game.deinit();
            tmp_dir.cleanup();
        }

        // A scene reload (e.g. F9 in the games) calls `loadScene`
        // again on the same game-lifetime `PrefabCache`. The eager
        // registry scan re-runs; without an idempotency guard it
        // would re-encounter every file the first scan registered and
        // wrongly raise `error.DuplicatePrefabName`. The scan tracks
        // already-walked directories, so the second call is a no-op
        // for the scan and must succeed.
        test "the second loadScene does not raise DuplicatePrefabName" {
            const scene_path = try tmpPath(&tmp_dir, "scenes/main.jsonc");
            defer zspec.allocator.free(scene_path);
            const prefab_dir = try tmpPath(&tmp_dir, "prefabs");
            defer zspec.allocator.free(prefab_dir);

            try Bridge.loadScene(&game, scene_path, prefab_dir);
            // Second load — must not error on the re-scan.
            try Bridge.loadScene(&game, scene_path, prefab_dir);

            // The prefab still resolves after the reload.
            try expect.notToBeNull(findMarker(&game, 99));
        }
    };
};
