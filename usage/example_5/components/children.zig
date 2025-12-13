const engine = @import("labelle-engine");
const Entity = engine.Entity;

/// Component that holds references to child entities (nested composition)
pub const Children = struct {
    items: []const Entity = &.{},
};
