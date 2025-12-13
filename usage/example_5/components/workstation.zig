const engine = @import("labelle-engine");
const Entity = engine.Entity;

/// Workstation component for kitchen work areas
pub const Workstation = struct {
    station_type: []const u8 = "generic",
    is_active: bool = true,
    /// Movement nodes for this workstation (nested entities)
    movement_nodes: []const Entity = &.{},
};
