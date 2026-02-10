// Script to test issue #268: destroying scene entities before scene deinit
//
// Press D to destroy an entity (simulates consuming an item)
// Press Escape or Q to quit
//
// The engine registers an entity destroy cleanup callback so that destroyed
// entities are removed from the scene's list at destroy time (zero per-frame cost).
// This means scene.deinit() never encounters already-destroyed entities.

const std = @import("std");
const engine = @import("labelle-engine");

const Game = engine.Game;
const Scene = engine.Scene;
const Entity = engine.Entity;

var destroyed_entity: ?Entity = null;

pub fn init(game: *Game, scene: *Scene) void {
    _ = game;
    std.log.info("[SceneTest] Script initialized.", .{});
    std.log.info("[SceneTest] Press D to destroy an entity, then Q to quit and verify no panic.", .{});

    // Get the first entity from the scene to destroy later
    if (scene.entities.items.len > 0) {
        destroyed_entity = scene.entities.items[0].entity;
        std.log.info("[SceneTest] Will destroy first scene entity on D key press", .{});
    }
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = scene;
    _ = dt;

    const input = game.getInput();

    // Press D to destroy an entity
    if (input.isKeyPressed(.d)) {
        if (destroyed_entity) |entity| {
            std.log.info("[SceneTest] Destroying scene entity during gameplay...", .{});
            game.destroyEntity(entity);
            destroyed_entity = null;
            std.log.info("[SceneTest] Entity destroyed! Press Q to quit and verify scene.deinit() doesn't panic.", .{});
        } else {
            std.log.info("[SceneTest] Entity already destroyed.", .{});
        }
    }

    // Press Q or Escape to quit
    if (input.isKeyPressed(.q) or input.isKeyPressed(.escape)) {
        std.log.info("[SceneTest] Quitting game - scene.deinit() will be called...", .{});
        game.quit();
    }
}

pub fn deinit(game: *Game, scene: *Scene) void {
    _ = game;
    _ = scene;
    std.log.info("[SceneTest] Script deinit called - if you see this, scene.deinit() succeeded!", .{});
}
