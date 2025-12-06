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
        if (ve.getPosition(entity_instance.sprite_id)) |pos| {
            const new_x = pos.x + vel.x * dt;
            const new_y = pos.y + vel.y * dt;
            _ = ve.setPosition(entity_instance.sprite_id, new_x, new_y);
        }
    }
}
