const engine = @import("labelle-engine");
const Velocity = @import("../components/velocity.zig").Velocity;
const Gravity = @import("../components/gravity.zig").Gravity;

const Game = engine.Game;
const Scene = engine.Scene;
const Position = engine.Position;

pub fn update(
    game: *Game,
    scene: *Scene,
    dt: f32,
) void {
    const registry = game.getRegistry();
    const pipeline = game.getPipeline();

    // Apply physics updates for entities with Velocity
    for (scene.entities.items) |entity_instance| {
        const vel = registry.getComponent(entity_instance.entity, Velocity) orelse continue;

        // Apply gravity if the entity has a Gravity component
        if (registry.getComponent(entity_instance.entity, Gravity)) |grav| {
            if (grav.enabled) {
                vel.y += grav.strength * dt;
            }
        }

        // Update position based on velocity
        if (registry.getComponent(entity_instance.entity, Position)) |pos| {
            pos.x += vel.x * dt;
            pos.y += vel.y * dt;
            // Mark position as dirty so RenderPipeline syncs it
            pipeline.markPositionDirty(entity_instance.entity);
        }
    }
}
