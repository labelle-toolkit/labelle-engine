const engine = @import("labelle-engine");
const Velocity = @import("../components/Velocity.zig").Velocity;

const Game = engine.Game;
const Scene = engine.Scene;
const Position = engine.Position;

// Screen bounds (matching window size from project.labelle)
const SCREEN_WIDTH: f32 = 800;
const SCREEN_HEIGHT: f32 = 600;
const MARGIN: f32 = 40; // Account for ball radius

pub fn update(
    game: *Game,
    scene: *Scene,
    dt: f32,
) void {
    const registry = game.getRegistry();
    const pipeline = game.getPipeline();

    // Update all entities with Position and Velocity
    for (scene.entities.items) |entity_instance| {
        const vel = registry.getComponent(entity_instance.entity, Velocity) orelse continue;
        const pos = registry.getComponent(entity_instance.entity, Position) orelse continue;

        // Update position based on velocity
        pos.x += vel.x * dt;
        pos.y += vel.y * dt;

        // Bounce off left/right walls
        if (pos.x < MARGIN) {
            pos.x = MARGIN;
            vel.x = -vel.x;
        } else if (pos.x > SCREEN_WIDTH - MARGIN) {
            pos.x = SCREEN_WIDTH - MARGIN;
            vel.x = -vel.x;
        }

        // Bounce off top/bottom walls
        if (pos.y < MARGIN) {
            pos.y = MARGIN;
            vel.y = -vel.y;
        } else if (pos.y > SCREEN_HEIGHT - MARGIN) {
            pos.y = SCREEN_HEIGHT - MARGIN;
            vel.y = -vel.y;
        }

        // Mark position as dirty so RenderPipeline syncs it
        pipeline.markPositionDirty(entity_instance.entity);
    }
}
