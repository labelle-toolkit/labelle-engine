// Movement script - updates shape positions based on velocity

const labelle = @import("labelle");
const engine_mod = @import("labelle-engine");

const VisualEngine = labelle.visual_engine.VisualEngine;
const Registry = engine_mod.Registry;
const Scene = engine_mod.Scene;

// Import main module to get component types
const main = @import("../main.zig");
const Velocity = main.Velocity;

pub fn update(registry: *Registry, ve: *VisualEngine, scene: *Scene, dt: f32) void {
    // Find entities with Velocity component and update their positions
    for (scene.entities.items) |*entity_instance| {
        if (entity_instance.visual_type == .shape) {
            if (registry.tryGet(Velocity, entity_instance.entity)) |vel| {
                // Get shape_id (it's optional now)
                const shape_id = entity_instance.shape_id orelse continue;

                // Get current position and update
                if (ve.getShapePosition(shape_id)) |pos| {
                    var new_x = pos.x + vel.x * dt;

                    // Wrap around screen
                    if (new_x > 820) {
                        new_x = -20;
                    } else if (new_x < -20) {
                        new_x = 820;
                    }

                    _ = ve.setShapePosition(shape_id, new_x, pos.y);
                }
            }
        }
    }
}
