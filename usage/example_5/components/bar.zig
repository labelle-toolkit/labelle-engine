const engine = @import("labelle-engine");
const Entity = engine.Entity;

pub const Bar = struct {
    bazzes: []const Entity = &.{},
};
