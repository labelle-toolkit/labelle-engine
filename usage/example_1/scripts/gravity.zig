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
        const vel = registry.tryGet(Velocity, entity_instance.entity) orelse continue;

        // Apply gravity if the entity has a Gravity component
        if (registry.tryGet(Gravity, entity_instance.entity)) |grav| {
            if (grav.enabled) {
                vel.y += grav.strength * dt;
            }
        }

        // Update position based on velocity
        if (registry.tryGet(Position, entity_instance.entity)) |pos| {
            pos.x += vel.x * dt;
            pos.y += vel.y * dt;
            // Mark position as dirty so RenderPipeline syncs it
            pipeline.markPositionDirty(entity_instance.entity);
        }
    }
}
