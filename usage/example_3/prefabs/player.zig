const engine = @import("labelle-engine");
const labelle = @import("labelle");

const ZIndex = labelle.visual_engine.ZIndex;

pub const name = "player";
pub const sprite = engine.prefab.SpriteConfig{
    .name = "idle_0001",
    .x = 400,
    .y = 300,
    .z_index = ZIndex.characters,
    .scale = 4.0,
};
