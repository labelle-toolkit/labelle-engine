const std = @import("std");
const engine = @import("labelle-engine");

/// Component that tracks when an entity was spawned.
/// Demonstrates the onAdd and onRemove callbacks.
pub const Spawned = struct {
    /// Timestamp when the entity was spawned (frame count)
    frame: u64 = 0,

    /// Called automatically when this component is added to an entity.
    pub fn onAdd(payload: engine.ComponentPayload) void {
        std.log.info("[Spawned.onAdd] Entity {d} has spawned!", .{payload.entity_id});
    }

    /// Called automatically when this component is removed from an entity.
    pub fn onRemove(payload: engine.ComponentPayload) void {
        std.log.info("[Spawned.onRemove] Entity {d} despawned!", .{payload.entity_id});
    }
};
