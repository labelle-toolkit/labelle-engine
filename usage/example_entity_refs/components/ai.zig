const std = @import("std");
const engine = @import("labelle-engine");
const ecs = @import("ecs");

const main = @import("../main.zig");
const Entity = engine.Entity;
const Game = engine.Game;

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

    /// Called after all entity references are resolved - validates target is set
    pub fn onReady(payload: engine.ComponentPayload) void {
        const game = payload.getGame(Game);
        const entity = engine.entityFromU64(payload.entity_id);
        const registry = game.getRegistry();

        const ai = registry.getComponent(entity, AI) orelse {
            std.log.err("[AI] FAIL: Could not get AI component", .{});
            return;
        };

        // Validate target is set (not zero)
        if (engine.entityToU64(ai.target) == 0) {
            std.log.err("[AI] FAIL: target is zero (not resolved)", .{});
            return;
        }

        // Validate target entity exists
        if (!registry.entityExists(ai.target)) {
            std.log.err("[AI] FAIL: target entity {} is invalid", .{engine.entityToU64(ai.target)});
            return;
        }

        // Validate target has Health component (it's the player)
        if (registry.getComponent(ai.target, main.Health)) |health| {
            std.log.info("[AI] OK: target resolved to entity {} with {}/{} health", .{
                engine.entityToU64(ai.target),
                health.current,
                health.max,
            });
        } else {
            std.log.err("[AI] FAIL: target {} has no Health component", .{engine.entityToU64(ai.target)});
        }
    }
};
