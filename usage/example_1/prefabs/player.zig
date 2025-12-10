const engine = @import("labelle-engine");

const ZIndex = engine.ZIndex;

pub const name = "player";
pub const sprite = engine.SpriteConfig{
    .name = "idle_0001",
    .x = 400,
    .y = 300,
    .z_index = ZIndex.characters,
    .scale = 4.0,
};
