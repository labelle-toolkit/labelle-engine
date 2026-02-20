const engine = @import("labelle-engine");
const Velocity = @import("../components/Velocity.zig").Velocity;

const Game = engine.Game;
const Scene = engine.Scene;
const Position = engine.Position;

const MARGIN: f32 = 40; // Account for ball radius

pub fn update(
    game: *Game,
    scene: *Scene,
    dt: f32,
) void {
    const registry = game.getRegistry();
    const pipeline = game.getPipeline();

    // Get screen size dynamically (works on all screen sizes including mobile)
    const screen_size = game.getScreenSize();
    const screen_width: f32 = @floatFromInt(screen_size.width);
    const screen_height: f32 = @floatFromInt(screen_size.height);

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
        } else if (pos.x > screen_width - MARGIN) {
            pos.x = screen_width - MARGIN;
            vel.x = -vel.x;
        }

        // Bounce off top/bottom walls
        if (pos.y < MARGIN) {
            pos.y = MARGIN;
            vel.y = -vel.y;
        } else if (pos.y > screen_height - MARGIN) {
            pos.y = screen_height - MARGIN;
            vel.y = -vel.y;
        }

        // Mark position as dirty so RenderPipeline syncs it
        pipeline.markPositionDirty(entity_instance.entity);
    }
}
