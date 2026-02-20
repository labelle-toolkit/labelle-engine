const std = @import("std");
const engine = @import("labelle-engine");
const ecs = @import("ecs");

const main = @import("../main.zig");
const Entity = engine.Entity;
const Game = engine.Game;

/// HealthBar component demonstrates self-references.
/// The `source` field references the same entity (via .ref = .self).
pub const HealthBar = struct {
    /// Entity to read health from (can be self or another entity)
    source: Entity = if (@hasDecl(Entity, "invalid")) Entity.invalid else @bitCast(@as(ecs.EntityBits, 0)),

    /// Visual offset from source entity
    offset_y: f32 = -30,

    /// Bar dimensions
    width: f32 = 40,
    height: f32 = 6,

    /// Called after all entity references are resolved - validates self-reference
    pub fn onReady(payload: engine.ComponentPayload) void {
        const game = payload.getGame(Game);
        const entity = engine.entityFromU64(payload.entity_id);
        const registry = game.getRegistry();

        const health_bar = registry.getComponent(entity, HealthBar) orelse {
            std.log.err("[HealthBar] FAIL: Could not get HealthBar component", .{});
            return;
        };

        // Validate source is set (not zero)
        if (engine.entityToU64(health_bar.source) == 0) {
            std.log.err("[HealthBar] FAIL: source is zero (not resolved)", .{});
            return;
        }

        // Validate self-reference: source should equal this entity
        const is_self = engine.entityToU64(health_bar.source) == engine.entityToU64(entity);
        if (!is_self) {
            std.log.err("[HealthBar] FAIL: expected self-reference but source={} != self={}", .{
                engine.entityToU64(health_bar.source),
                engine.entityToU64(entity),
            });
            return;
        }

        // Validate we can read Health from source (self)
        if (registry.getComponent(health_bar.source, main.Health)) |health| {
            std.log.info("[HealthBar] OK: self-reference resolved, health={}/{}", .{
                health.current,
                health.max,
            });
        } else {
            std.log.err("[HealthBar] FAIL: source entity has no Health component", .{});
        }
    }
};
