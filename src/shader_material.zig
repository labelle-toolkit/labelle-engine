//! Game-owned effects bind generic materials; catalog pins belong to the engine.
const core = @import("labelle-core");
pub const contract = core.shader_material;
pub const Texture = union(enum) { catalog: []const u8, id: core.TextureId };
pub const TextureBinding = struct {
    name: [:0]const u8,
    texture: Texture,
    sampler: contract.Sampler = .point,
};
pub const Descriptor = struct {
    version: u32 = contract.VERSION,
    label: []const u8 = "",
    shaders: contract.ShaderVariants,
    parameters: []const contract.Parameter = &.{},
    textures: []const TextureBinding = &.{},
    blend: contract.Blend = .alpha,
};
pub const HeldTexture = struct { name: []const u8, catalog: ?[]const u8 = null };
pub const Record = struct {
    id: contract.Id,
    textures: [contract.MAX_TEXTURES]HeldTexture = undefined,
    len: usize = 0,
};

pub const Pending = struct { name: []const u8, key: []const u8 };
