const std = @import("std");
const zspec = @import("zspec");
const expect = zspec.expect;

const engine = @import("labelle-engine");
const ecs = @import("ecs");

const Game = engine.Game;
const Scene = engine.Scene;
const SceneContext = engine.SceneContext;
const EntityInstance = engine.EntityInstance;
const Entity = engine.Entity;
const RenderPipeline = engine.RenderPipeline;

test {
    zspec.runAll(@This());
}

// Note: Scene and SceneContext have circular dependency with script.UpdateFn
// so we can only test the module exports without triggering the dependency loop

pub const MODULE_EXPORTS = struct {
    pub const PREFAB_EXPORTS = struct {
        test "exports SpriteConfig type" {
            try expect.toBeTrue(@hasDecl(engine, "SpriteConfig"));
        }

        test "exports PrefabRegistry function" {
            try expect.toBeTrue(@hasDecl(engine, "PrefabRegistry"));
        }
    };

    pub const LOADER_EXPORTS = struct {
        test "exports SceneLoader function" {
            try expect.toBeTrue(@hasDecl(engine, "SceneLoader"));
        }
    };

    pub const COMPONENT_EXPORTS = struct {
        test "exports ComponentRegistry function" {
            try expect.toBeTrue(@hasDecl(engine, "ComponentRegistry"));
        }
    };

    pub const SCRIPT_EXPORTS = struct {
        test "exports ScriptRegistry function" {
            try expect.toBeTrue(@hasDecl(engine, "ScriptRegistry"));
        }
    };

    pub const SCENE_EXPORTS = struct {
        test "exports Scene type" {
            try expect.toBeTrue(@hasDecl(engine, "Scene"));
        }

        test "exports SceneContext type" {
            try expect.toBeTrue(@hasDecl(engine, "SceneContext"));
        }

        test "exports EntityInstance type" {
            try expect.toBeTrue(@hasDecl(engine, "EntityInstance"));
        }
    };

    pub const EXTERNAL_EXPORTS = struct {
        test "exports Game type" {
            try expect.toBeTrue(@hasDecl(engine, "Game"));
        }

        test "exports RenderPipeline type" {
            try expect.toBeTrue(@hasDecl(engine, "RenderPipeline"));
        }

        test "exports RetainedEngine type" {
            try expect.toBeTrue(@hasDecl(engine, "RetainedEngine"));
        }

        test "exports Position type" {
            try expect.toBeTrue(@hasDecl(engine, "Position"));
        }

        test "exports Sprite type" {
            try expect.toBeTrue(@hasDecl(engine, "Sprite"));
        }

        test "exports Shape type" {
            try expect.toBeTrue(@hasDecl(engine, "Shape"));
        }

        test "exports Registry type" {
            try expect.toBeTrue(@hasDecl(engine, "Registry"));
        }

        test "exports Entity type" {
            try expect.toBeTrue(@hasDecl(engine, "Entity"));
        }
    };

    pub const SUBMODULE_EXPORTS = struct {
        test "exports prefab submodule" {
            try expect.toBeTrue(@hasDecl(engine.scene, "prefab"));
        }

        test "exports loader submodule" {
            try expect.toBeTrue(@hasDecl(engine.scene, "loader"));
        }

        test "exports component submodule" {
            try expect.toBeTrue(@hasDecl(engine.scene, "component"));
        }

        test "exports script submodule" {
            try expect.toBeTrue(@hasDecl(engine.scene, "script"));
        }
    };
};

// ============================================
// ENTITY DESTROY CLEANUP (Issue #268)
// ============================================

fn createTestGame() Game {
    const alloc = std.testing.allocator;
    var game: Game = undefined;
    game.allocator = alloc;
    game.registry = ecs.Registry.init(alloc);
    game.pipeline = RenderPipeline.init(alloc, undefined);
    game.on_entity_destroy_cleanup = null;
    return game;
}

fn fixTestGamePointers(game: *Game) void {
    game.pipeline.registry = &game.registry;
}

fn deinitTestGame(game: *Game) void {
    game.pipeline.deinit();
    game.registry.deinit();
}

pub const ENTITY_DESTROY_CLEANUP = struct {
    pub const REMOVE_ENTITY = struct {
        test "removeEntity removes entity from scene list" {
            var game = createTestGame();
            fixTestGamePointers(&game);
            defer deinitTestGame(&game);

            const ctx = SceneContext.init(&game);
            var scene = Scene.init("test", &.{}, &.{}, ctx);
            defer scene.entities.deinit(std.testing.allocator);

            const e1 = game.registry.create();
            const e2 = game.registry.create();
            const e3 = game.registry.create();

            try scene.addEntity(.{ .entity = e1 });
            try scene.addEntity(.{ .entity = e2 });
            try scene.addEntity(.{ .entity = e3 });

            try expect.equal(scene.entityCount(), 3);

            scene.removeEntity(e2);

            try expect.equal(scene.entityCount(), 2);
        }

        test "removeEntity with nonexistent entity is a no-op" {
            var game = createTestGame();
            fixTestGamePointers(&game);
            defer deinitTestGame(&game);

            const ctx = SceneContext.init(&game);
            var scene = Scene.init("test", &.{}, &.{}, ctx);
            defer scene.entities.deinit(std.testing.allocator);

            const e1 = game.registry.create();
            const e2 = game.registry.create();

            try scene.addEntity(.{ .entity = e1 });

            scene.removeEntity(e2);

            try expect.equal(scene.entityCount(), 1);
        }

        test "removeEntity on empty scene is a no-op" {
            var game = createTestGame();
            fixTestGamePointers(&game);
            defer deinitTestGame(&game);

            const ctx = SceneContext.init(&game);
            var scene = Scene.init("test", &.{}, &.{}, ctx);
            defer scene.entities.deinit(std.testing.allocator);

            const e1 = game.registry.create();

            scene.removeEntity(e1);

            try expect.equal(scene.entityCount(), 0);
        }
    };

    pub const CALLBACK_WIRING = struct {
        test "destroyEntity removes entity from scene list via callback" {
            var game = createTestGame();
            fixTestGamePointers(&game);
            defer deinitTestGame(&game);

            const ctx = SceneContext.init(&game);
            var scene = Scene.init("test", &.{}, &.{}, ctx);
            defer scene.entities.deinit(std.testing.allocator);

            const e1 = game.registry.create();
            const e2 = game.registry.create();

            try scene.addEntity(.{ .entity = e1 });
            try scene.addEntity(.{ .entity = e2 });

            // Register callback via initScripts (the public API)
            scene.initScripts();
            defer {
                game.on_entity_destroy_cleanup = null;
            }

            try expect.equal(scene.entityCount(), 2);

            // Destroy entity through Game — should trigger callback and remove from scene
            game.destroyEntity(e1);

            try expect.equal(scene.entityCount(), 1);
            try expect.equal(scene.entities.items[0].entity, e2);
        }

        test "destroyed entity is not in scene list during deinit" {
            var game = createTestGame();
            fixTestGamePointers(&game);
            defer deinitTestGame(&game);

            const ctx = SceneContext.init(&game);
            var scene = Scene.init("test", &.{}, &.{}, ctx);

            const e1 = game.registry.create();
            const e2 = game.registry.create();
            const e3 = game.registry.create();

            try scene.addEntity(.{ .entity = e1 });
            try scene.addEntity(.{ .entity = e2 });
            try scene.addEntity(.{ .entity = e3 });

            // Register callback via initScripts
            scene.initScripts();

            game.destroyEntity(e2);

            // Only 2 entities remain — deinit should destroy them cleanly (no panic)
            try expect.equal(scene.entityCount(), 2);
            scene.deinit();
        }
    };
};
