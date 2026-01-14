const std = @import("std");
const engine = @import("labelle-engine");
const ecs = @import("ecs");

const Entity = engine.Entity;

/// AI component demonstrates entity references.
/// The `target` field references another entity (e.g., the player).
pub const AI = struct {
    /// Current AI state
    state: State = .idle,

    /// Target entity to track/chase (populated from .ref syntax)
    target: Entity = if (@hasDecl(Entity, "invalid")) Entity.invalid else @bitCast(@as(ecs.EntityBits, 0)),

    pub const State = enum {
        idle,
        chasing,
        attacking,
    };

    pub fn onAdd(payload: engine.ComponentPayload) void {
        _ = payload;
        std.log.info("[AI.onAdd] AI component added", .{});
    }

    /// Called after all entity references are resolved
    pub fn onReady(payload: engine.ComponentPayload) void {
        _ = payload;
        std.log.info("[AI.onReady] AI target reference resolved!", .{});
    }
};
