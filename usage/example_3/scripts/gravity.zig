const engine = @import("labelle-engine");
const labelle = @import("labelle");
const Velocity = @import("../components/velocity.zig").Velocity;
const Gravity = @import("../components/gravity.zig").Gravity;

const VisualEngine = labelle.visual_engine.VisualEngine;

pub fn update(
    registry: *engine.Registry,
    ve: *VisualEngine,
    scene: *engine.Scene,
    dt: f32,
) void {
    // Apply gravity and update positions for entities with Velocity and Gravity
    for (scene.entities.items) |entity_instance| {
        const vel = registry.tryGet(Velocity, entity_instance.entity) orelse continue;
        const grav = registry.tryGet(Gravity, entity_instance.entity) orelse continue;

        if (grav.enabled) {
            // Apply gravity to velocity
            vel.y += grav.strength * dt;

            // Get current position and update with velocity
            if (ve.getPosition(entity_instance.sprite_id)) |pos| {
                const new_y = pos.y + vel.y * dt;
                _ = ve.setPosition(entity_instance.sprite_id, pos.x, new_y);
            }
        }
    }
}
