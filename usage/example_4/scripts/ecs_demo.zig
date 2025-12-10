// ECS Demo Script - Demonstrates ECS operations that work with any backend
//
// This example shows how the ECS interface abstracts away the underlying
// implementation. Whether you use zig_ecs or zcs, the API is identical:
//
//   - registry.create()      -> Create a new entity
//   - registry.add(e, comp)  -> Add a component to an entity
//   - registry.tryGet(T, e)  -> Get a component (returns ?*T)
//   - registry.remove(T, e)  -> Remove a component
//   - registry.destroy(e)    -> Destroy an entity
//
// Build with different backends:
//   zig build run                      # Uses zig_ecs (default)
//   zig build run -Decs_backend=zcs   # Uses zcs backend

const engine = @import("labelle-engine");
const Bouncer = @import("../components/bouncer.zig").Bouncer;

const Game = engine.Game;
const Scene = engine.Scene;
const Position = engine.Position;
const Shape = engine.Shape;
const Color = engine.Color;

// Screen bounds for bouncing
const SCREEN_WIDTH: f32 = 800;
const SCREEN_HEIGHT: f32 = 600;
const MARGIN: f32 = 30;

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    const registry = game.getRegistry();
    const pipeline = game.getPipeline();

    // Update all entities with Bouncer component
    // This demonstrates registry.tryGet() which works identically on all backends
    for (scene.entities.items) |entity_instance| {
        const bouncer = registry.tryGet(Bouncer, entity_instance.entity) orelse continue;
        const pos = registry.tryGet(Position, entity_instance.entity) orelse continue;

        // Move the entity
        pos.x += bouncer.speed_x * dt;
        pos.y += bouncer.speed_y * dt;

        // Bounce off screen edges
        if (pos.x < MARGIN or pos.x > SCREEN_WIDTH - MARGIN) {
            bouncer.speed_x = -bouncer.speed_x;
            pos.x = @max(MARGIN, @min(pos.x, SCREEN_WIDTH - MARGIN));
        }
        if (pos.y < MARGIN or pos.y > SCREEN_HEIGHT - MARGIN) {
            bouncer.speed_y = -bouncer.speed_y;
            pos.y = @max(MARGIN, @min(pos.y, SCREEN_HEIGHT - MARGIN));
        }

        // Mark position dirty so the render pipeline syncs it
        pipeline.markPositionDirty(entity_instance.entity);
    }
}
