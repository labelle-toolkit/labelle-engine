const std = @import("std");
const engine = @import("labelle-engine");
const ecs = @import("ecs");

const Entity = engine.Entity;

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

    pub fn onReady(payload: engine.ComponentPayload) void {
        _ = payload;
        std.log.info("[HealthBar.onReady] HealthBar self-reference resolved!", .{});
    }
};
