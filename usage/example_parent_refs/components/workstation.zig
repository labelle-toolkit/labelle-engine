const std = @import("std");
const engine = @import("labelle-engine");

const Entity = engine.Entity;

/// Workstation component demonstrates nested entity creation.
/// The `storages` field contains Entity references that are automatically
/// created when the workstation prefab is loaded.
pub const Workstation = struct {
    /// How long the workstation takes to process items
    process_duration: u32 = 60,

    /// Nested entities - automatically created from prefab definitions.
    /// Each Storage entity will have its `workstation` field auto-populated
    /// with this workstation's entity (parent reference convention).
    storages: []const Entity = &.{},

    /// onReady is called after the entire hierarchy is complete.
    /// At this point, all storages exist and `storages` array is populated.
    pub fn onReady(payload: engine.ComponentPayload) void {
        _ = payload;
        std.log.info("[Workstation.onReady] Workstation hierarchy complete!", .{});
    }

    /// onAdd is called immediately when component is added.
    /// Note: `storages` array may not be fully populated yet.
    pub fn onAdd(payload: engine.ComponentPayload) void {
        _ = payload;
        std.log.info("[Workstation.onAdd] Workstation component added.", .{});
    }
};
