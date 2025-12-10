const engine = @import("labelle-engine");

const ZIndex = engine.ZIndex;

pub const name = "enemy";
pub const sprite = engine.SpriteConfig{
    .name = "walk_0001",
    .z_index = ZIndex.characters,
    .scale = 3.0,
};
