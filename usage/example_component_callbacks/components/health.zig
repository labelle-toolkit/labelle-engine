const std = @import("std");
const engine = @import("labelle-engine");

/// Health component with full lifecycle callbacks.
/// Demonstrates onAdd, onSet, and onRemove callbacks.
pub const Health = struct {
    current: i32 = 100,
    max: i32 = 100,

    /// Called automatically when Health is added to an entity.
    pub fn onAdd(payload: engine.ComponentPayload) void {
        std.log.info("[Health.onAdd] Entity {d} now has health!", .{payload.entity_id});
    }

    /// Called when Health component value is set/replaced.
    /// Note: This fires on component replacement, not direct field mutation.
    pub fn onSet(payload: engine.ComponentPayload) void {
        std.log.info("[Health.onSet] Entity {d} health was modified!", .{payload.entity_id});
    }

    /// Called when Health component is removed from an entity.
    pub fn onRemove(payload: engine.ComponentPayload) void {
        std.log.info("[Health.onRemove] Entity {d} lost its health component!", .{payload.entity_id});
    }
};
