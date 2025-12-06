const engine = @import("labelle-engine");
const labelle = @import("labelle");

const ZIndex = labelle.visual_engine.ZIndex;

pub const name = "enemy";
pub const sprite = engine.prefab.SpriteConfig{
    .name = "walk_0001",
    .z_index = ZIndex.characters,
    .scale = 3.0,
};
