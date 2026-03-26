const std = @import("std");
const expect = @import("zspec").expect;
const jsonc = @import("jsonc");
const HotReloader = jsonc.hot_reload.HotReloader;
const SimulatedGame = jsonc.hot_reload.SimulatedGame;
const Scene = jsonc.scene_loader.Scene;

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.testing.allocator);
}

// ── HotReloader ──

pub const hot_reloader = struct {
    pub const initial_load = struct {
        test "loads scene from file on disk" {
            var arena = testArena();
            defer arena.deinit();
            const alloc = arena.allocator();

            var tmp_dir = std.testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            try tmp_dir.dir.writeFile(.{
                .sub_path = "scene.jsonc",
                .data =
                \\{
                \\    "name": "test",
                \\    "scripts": [],
                \\    "entities": [
                \\        { "components": { "Position": { "x": 10, "y": 20 } } }
                \\    ]
                \\}
                ,
            });

            const scene_path = try tmp_dir.dir.realpathAlloc(alloc, "scene.jsonc");

            var reloader = HotReloader.init(alloc, scene_path, "nonexistent");
            defer reloader.deinit();

            try reloader.load();

            const scene = reloader.getScene().?;
            try expect.equal(scene.name, "test");
            try expect.equal(scene.entities.len, 1);
            try expect.equal(reloader.reload_count, 1);
        }

        test "scene is null before load" {
            var reloader = HotReloader.init(std.testing.allocator, "fake", "fake");
            defer reloader.deinit();

            try expect.to_be_null(reloader.getScene());
            try expect.equal(reloader.reload_count, 0);
        }
    };

    pub const force_reload = struct {
        test "picks up file changes" {
            var arena = testArena();
            defer arena.deinit();
            const alloc = arena.allocator();

            var tmp_dir = std.testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            try tmp_dir.dir.writeFile(.{
                .sub_path = "scene.jsonc",
                .data =
                \\{
                \\    "name": "v1",
                \\    "scripts": [],
                \\    "entities": [
                \\        { "components": { "Position": { "x": 10, "y": 20 } } }
                \\    ]
                \\}
                ,
            });

            const scene_path = try tmp_dir.dir.realpathAlloc(alloc, "scene.jsonc");

            var reloader = HotReloader.init(alloc, scene_path, "nonexistent");
            defer reloader.deinit();

            try reloader.load();
            try expect.equal(reloader.getScene().?.name, "v1");
            try expect.equal(reloader.getScene().?.entities.len, 1);

            // Modify scene: 3 entities, new name
            try tmp_dir.dir.writeFile(.{
                .sub_path = "scene.jsonc",
                .data =
                \\{
                \\    "name": "v2",
                \\    "scripts": ["new_script"],
                \\    "entities": [
                \\        { "components": { "Position": { "x": 10, "y": 20 } } },
                \\        { "components": { "Position": { "x": 30, "y": 40 } } },
                \\        { "components": { "Position": { "x": 50, "y": 60 } } }
                \\    ]
                \\}
                ,
            });

            try reloader.forceReload();
            try expect.equal(reloader.getScene().?.name, "v2");
            try expect.equal(reloader.getScene().?.entities.len, 3);
            try expect.equal(reloader.getScene().?.scripts.len, 1);
            try expect.equal(reloader.reload_count, 2);
        }

        test "updates reload count on each force reload" {
            var arena = testArena();
            defer arena.deinit();
            const alloc = arena.allocator();

            var tmp_dir = std.testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            try tmp_dir.dir.writeFile(.{
                .sub_path = "scene.jsonc",
                .data =
                \\{ "name": "s", "scripts": [], "entities": [] }
                ,
            });

            const scene_path = try tmp_dir.dir.realpathAlloc(alloc, "scene.jsonc");

            var reloader = HotReloader.init(alloc, scene_path, "nonexistent");
            defer reloader.deinit();

            try reloader.load();
            try reloader.forceReload();
            try reloader.forceReload();
            try expect.equal(reloader.reload_count, 3);
        }
    };

    pub const poll = struct {
        test "returns false when no changes" {
            var arena = testArena();
            defer arena.deinit();
            const alloc = arena.allocator();

            var tmp_dir = std.testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            try tmp_dir.dir.writeFile(.{
                .sub_path = "scene.jsonc",
                .data =
                \\{ "name": "original", "scripts": [], "entities": [] }
                ,
            });

            const scene_path = try tmp_dir.dir.realpathAlloc(alloc, "scene.jsonc");

            var reloader = HotReloader.init(alloc, scene_path, "nonexistent");
            defer reloader.deinit();

            try reloader.load();

            const changed = try reloader.poll();
            try expect.to_be_false(changed);
            try expect.equal(reloader.reload_count, 1);
        }

        test "detects mtime changes and reloads" {
            var arena = testArena();
            defer arena.deinit();
            const alloc = arena.allocator();

            var tmp_dir = std.testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            try tmp_dir.dir.writeFile(.{
                .sub_path = "scene.jsonc",
                .data =
                \\{ "name": "original", "scripts": [], "entities": [] }
                ,
            });

            const scene_path = try tmp_dir.dir.realpathAlloc(alloc, "scene.jsonc");

            var reloader = HotReloader.init(alloc, scene_path, "nonexistent");
            defer reloader.deinit();

            try reloader.load();

            // Sleep briefly to ensure mtime changes (filesystem granularity)
            std.Thread.sleep(10 * std.time.ns_per_ms);

            try tmp_dir.dir.writeFile(.{
                .sub_path = "scene.jsonc",
                .data =
                \\{
                \\    "name": "modified",
                \\    "scripts": [],
                \\    "entities": [
                \\        { "components": { "Marker": {} } }
                \\    ]
                \\}
                ,
            });

            const changed = try reloader.poll();
            try expect.to_be_true(changed);
            try expect.equal(reloader.getScene().?.name, "modified");
            try expect.equal(reloader.getScene().?.entities.len, 1);
            try expect.equal(reloader.reload_count, 2);
        }

        test "returns false after reload when no new changes" {
            var arena = testArena();
            defer arena.deinit();
            const alloc = arena.allocator();

            var tmp_dir = std.testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            try tmp_dir.dir.writeFile(.{
                .sub_path = "scene.jsonc",
                .data =
                \\{ "name": "s", "scripts": [], "entities": [] }
                ,
            });

            const scene_path = try tmp_dir.dir.realpathAlloc(alloc, "scene.jsonc");

            var reloader = HotReloader.init(alloc, scene_path, "nonexistent");
            defer reloader.deinit();

            try reloader.load();

            std.Thread.sleep(10 * std.time.ns_per_ms);

            try tmp_dir.dir.writeFile(.{
                .sub_path = "scene.jsonc",
                .data =
                \\{ "name": "changed", "scripts": [], "entities": [] }
                ,
            });

            _ = try reloader.poll(); // triggers reload

            // No new changes
            const changed = try reloader.poll();
            try expect.to_be_false(changed);
            try expect.equal(reloader.reload_count, 2);
        }
    };

    pub const memory = struct {
        test "arena is properly recycled on reload — 100 consecutive reloads" {
            var arena = testArena();
            defer arena.deinit();
            const alloc = arena.allocator();

            var tmp_dir = std.testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            try tmp_dir.dir.writeFile(.{
                .sub_path = "scene.jsonc",
                .data =
                \\{ "name": "v1", "scripts": [], "entities": [] }
                ,
            });

            const scene_path = try tmp_dir.dir.realpathAlloc(alloc, "scene.jsonc");

            var reloader = HotReloader.init(alloc, scene_path, "nonexistent");
            defer reloader.deinit();

            try reloader.load();
            for (0..100) |_| {
                try reloader.forceReload();
            }
            try expect.equal(reloader.reload_count, 101);
            try expect.equal(reloader.getScene().?.name, "v1");
        }
    };

    pub const prefab_tracking = struct {
        test "prefab file changes trigger reload" {
            var arena = testArena();
            defer arena.deinit();
            const alloc = arena.allocator();

            var tmp_dir = std.testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            try tmp_dir.dir.makeDir("prefabs");

            try tmp_dir.dir.writeFile(.{
                .sub_path = "prefabs/enemy.jsonc",
                .data =
                \\{ "components": { "Enemy": {}, "Health": { "hp": 100 } } }
                ,
            });

            try tmp_dir.dir.writeFile(.{
                .sub_path = "scene.jsonc",
                .data =
                \\{
                \\    "name": "level1",
                \\    "scripts": [],
                \\    "entities": [
                \\        { "prefab": "enemy", "components": { "Position": { "x": 50, "y": 50 } } }
                \\    ]
                \\}
                ,
            });

            const scene_path = try tmp_dir.dir.realpathAlloc(alloc, "scene.jsonc");
            const prefab_dir = try tmp_dir.dir.realpathAlloc(alloc, "prefabs");

            var reloader = HotReloader.init(alloc, scene_path, prefab_dir);
            defer reloader.deinit();

            try reloader.load();
            const scene1 = reloader.getScene().?;
            try expect.equal(scene1.entities.len, 1);
            try expect.to_be_true(scene1.entities[0].hasComponent("Enemy"));
            try expect.to_be_true(scene1.entities[0].hasComponent("Health"));

            // No changes yet
            try expect.to_be_false(try reloader.poll());

            // Modify the prefab — add Armor component
            std.Thread.sleep(10 * std.time.ns_per_ms);
            try tmp_dir.dir.writeFile(.{
                .sub_path = "prefabs/enemy.jsonc",
                .data =
                \\{ "components": { "Enemy": {}, "Health": { "hp": 200 }, "Armor": { "defense": 50 } } }
                ,
            });

            // Poll should detect prefab change
            const changed = try reloader.poll();
            try expect.to_be_true(changed);

            const scene2 = reloader.getScene().?;
            try expect.to_be_true(scene2.entities[0].hasComponent("Enemy"));
            try expect.to_be_true(scene2.entities[0].hasComponent("Health"));
            try expect.to_be_true(scene2.entities[0].hasComponent("Armor"));
            try expect.equal(reloader.reload_count, 2);
        }

        test "watches only .jsonc files in prefab directory" {
            var arena = testArena();
            defer arena.deinit();
            const alloc = arena.allocator();

            var tmp_dir = std.testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            try tmp_dir.dir.makeDir("prefabs");

            try tmp_dir.dir.writeFile(.{
                .sub_path = "prefabs/enemy.jsonc",
                .data =
                \\{ "components": { "Enemy": {} } }
                ,
            });

            // Non-jsonc file should be ignored
            try tmp_dir.dir.writeFile(.{
                .sub_path = "prefabs/notes.txt",
                .data = "some notes",
            });

            try tmp_dir.dir.writeFile(.{
                .sub_path = "scene.jsonc",
                .data =
                \\{ "name": "s", "scripts": [], "entities": [] }
                ,
            });

            const scene_path = try tmp_dir.dir.realpathAlloc(alloc, "scene.jsonc");
            const prefab_dir = try tmp_dir.dir.realpathAlloc(alloc, "prefabs");

            var reloader = HotReloader.init(alloc, scene_path, prefab_dir);
            defer reloader.deinit();

            try reloader.load();

            // Modify the non-jsonc file — should NOT trigger reload
            std.Thread.sleep(10 * std.time.ns_per_ms);
            try tmp_dir.dir.writeFile(.{
                .sub_path = "prefabs/notes.txt",
                .data = "updated notes",
            });

            try expect.to_be_false(try reloader.poll());
            try expect.equal(reloader.reload_count, 1);
        }
    };

    pub const timing = struct {
        test "reload timing is tracked" {
            var arena = testArena();
            defer arena.deinit();
            const alloc = arena.allocator();

            var tmp_dir = std.testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            try tmp_dir.dir.writeFile(.{
                .sub_path = "scene.jsonc",
                .data =
                \\{ "name": "bench", "scripts": [], "entities": [] }
                ,
            });

            const scene_path = try tmp_dir.dir.realpathAlloc(alloc, "scene.jsonc");

            var reloader = HotReloader.init(alloc, scene_path, "nonexistent");
            defer reloader.deinit();

            try reloader.load();
            try expect.to_be_true(reloader.last_reload_time_ns > 0);
        }
    };

    pub const callbacks = struct {
        var before_called: bool = false;
        var after_called: bool = false;
        var after_entity_count: usize = 0;

        fn resetCallbacks() void {
            before_called = false;
            after_called = false;
            after_entity_count = 0;
        }

        fn onBefore(_: Scene) void {
            before_called = true;
        }

        fn onAfter(scene: Scene) void {
            after_called = true;
            after_entity_count = scene.entities.len;
        }

        test "invokes before and after reload callbacks" {
            resetCallbacks();

            var arena = testArena();
            defer arena.deinit();
            const alloc = arena.allocator();

            var tmp_dir = std.testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            try tmp_dir.dir.writeFile(.{
                .sub_path = "scene.jsonc",
                .data =
                \\{
                \\    "name": "cb_test",
                \\    "scripts": [],
                \\    "entities": [
                \\        { "components": { "A": {} } },
                \\        { "components": { "B": {} } }
                \\    ]
                \\}
                ,
            });

            const scene_path = try tmp_dir.dir.realpathAlloc(alloc, "scene.jsonc");

            var reloader = HotReloader.init(alloc, scene_path, "nonexistent");
            defer reloader.deinit();

            reloader.on_before_reload = &onBefore;
            reloader.on_after_reload = &onAfter;

            // Initial load — no before callback (no existing scene)
            try reloader.load();
            try expect.to_be_false(before_called);
            try expect.to_be_true(after_called);
            try expect.equal(after_entity_count, 2);

            resetCallbacks();

            // Force reload — both callbacks should fire
            try reloader.forceReload();
            try expect.to_be_true(before_called);
            try expect.to_be_true(after_called);
        }
    };
};

// ── SimulatedGame ──

pub const simulated_game = struct {
    test "start loads scene and logs reload event" {
        var arena = testArena();
        defer arena.deinit();
        const alloc = arena.allocator();

        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();

        try tmp_dir.dir.writeFile(.{
            .sub_path = "scene.jsonc",
            .data =
            \\{
            \\    "name": "game",
            \\    "scripts": ["physics"],
            \\    "entities": [
            \\        { "components": { "Position": { "x": 0, "y": 0 } } }
            \\    ]
            \\}
            ,
        });

        const scene_path = try tmp_dir.dir.realpathAlloc(alloc, "scene.jsonc");

        var game = SimulatedGame.init(alloc, scene_path, "nonexistent");
        defer game.deinit();

        try game.start();
        try expect.equal(game.reload_log.items.len, 1);
        try expect.equal(game.reload_log.items[0].scene_name, "game");
        try expect.equal(game.reload_log.items[0].entity_count, 1);
    }

    test "ticking without changes does not reload" {
        var arena = testArena();
        defer arena.deinit();
        const alloc = arena.allocator();

        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();

        try tmp_dir.dir.writeFile(.{
            .sub_path = "scene.jsonc",
            .data =
            \\{ "name": "game", "scripts": [], "entities": [] }
            ,
        });

        const scene_path = try tmp_dir.dir.realpathAlloc(alloc, "scene.jsonc");

        var game = SimulatedGame.init(alloc, scene_path, "nonexistent");
        defer game.deinit();

        try game.start();

        for (0..10) |_| {
            try game.tick();
        }
        try expect.equal(game.frame_count, 10);
        try expect.equal(game.reload_log.items.len, 1); // no extra reloads
    }

    test "manual reload (F5) logs reload event with frame number" {
        var arena = testArena();
        defer arena.deinit();
        const alloc = arena.allocator();

        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();

        try tmp_dir.dir.writeFile(.{
            .sub_path = "scene.jsonc",
            .data =
            \\{
            \\    "name": "game",
            \\    "scripts": [],
            \\    "entities": [
            \\        { "components": { "Position": { "x": 0, "y": 0 } } }
            \\    ]
            \\}
            ,
        });

        const scene_path = try tmp_dir.dir.realpathAlloc(alloc, "scene.jsonc");

        var game = SimulatedGame.init(alloc, scene_path, "nonexistent");
        defer game.deinit();

        try game.start();

        // Simulate 10 frames then F5
        for (0..10) |_| {
            try game.tick();
        }

        try game.reload();
        try expect.equal(game.reload_log.items.len, 2);
        try expect.equal(game.reload_log.items[1].frame, 10);
    }
};
