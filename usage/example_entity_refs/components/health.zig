const std = @import("std");
const engine = @import("labelle-engine");

/// Health component for entities that can take damage.
pub const Health = struct {
    current: i32 = 100,
    max: i32 = 100,

    pub fn onAdd(payload: engine.ComponentPayload) void {
        _ = payload;
        std.log.info("[Health.onAdd] Health component added", .{});
    }
};
