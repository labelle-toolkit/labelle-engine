const engine = @import("labelle-engine");
const Velocity = @import("../components/velocity.zig").Velocity;

const Game = engine.Game;
const Scene = engine.Scene;
const Position = engine.Position;

const MOVE_SPEED: f32 = 200.0;
const JUMP_FORCE: f32 = -400.0;

pub fn update(
    game: *Game,
    scene: *Scene,
    dt: f32,
) void {
    const registry = game.getRegistry();
    const pipeline = game.getPipeline();
    const input = game.getInput();

    // Find player entity (first entity with Velocity component)
    for (scene.entities.items) |entity_instance| {
        const vel = registry.getComponent(entity_instance.entity, Velocity) orelse continue;

        // Horizontal movement with arrow keys or WASD
        if (input.isKeyDown(.left) or input.isKeyDown(.a)) {
            vel.x = -MOVE_SPEED;
        } else if (input.isKeyDown(.right) or input.isKeyDown(.d)) {
            vel.x = MOVE_SPEED;
        } else {
            vel.x = 0;
        }

        // Jump with space (only when pressed, not held)
        if (input.isKeyPressed(.space)) {
            vel.y = JUMP_FORCE;
        }

        // Update position based on velocity
        if (registry.getComponent(entity_instance.entity, Position)) |pos| {
            pos.x += vel.x * dt;
            pos.y += vel.y * dt;

            // Simple ground collision (stop at y = 300)
            if (pos.y > 300) {
                pos.y = 300;
                vel.y = 0;
            }

            // Mark position as dirty so RenderPipeline syncs it
            pipeline.markPositionDirty(entity_instance.entity);
        }

        // Quit on escape
        if (input.isKeyPressed(.escape)) {
            game.quit();
        }

        // Toggle fullscreen on F11
        if (input.isKeyPressed(.f11)) {
            game.toggleFullscreen();
        }

        // Only control first entity with velocity
        break;
    }
}
