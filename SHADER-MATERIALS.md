# Game-owned shader materials

Game components such as WaterShader, FogShader, and LampShader own effect state and immutable shader definitions. The engine provides no effect-specific component or simulation.

```zig
try game.createShaderMaterial(entity, .{
    .label = "water",
    .shaders = materials.water.shaders,
    .parameters = &materials.water.parameters,
    .textures = &.{.{
        .name = "s_water_mask",
        .texture = .{ .catalog = water.mask },
        .sampler = .point,
    }},
});
try game.setShaderParameter(entity, "u_time", &.{time});
try game.setShaderTexture(entity, "s_water_mask", "replacement_mask");
game.clearShaderMaterial(entity);
```

`ShaderMaterialDescriptor` mirrors `core.shader_material.Descriptor`, except `textures` contains `ShaderTextureBinding` values. Each texture is `ShaderTexture{ .catalog = key }` or `{ .id = TextureId }`. The setter also accepts a catalog string or a typed `TextureId` directly. No backend import or backend texture id is needed. Parameters and shader fragments use core's shared types. Fragment variants pair with the backend sprite vertex shader; the backend supplies the reserved `u_material_rect` atlas uniform.

Creation requires a live sprite and returns `!void`; `shaderMaterial(entity)` returns the current optional runtime id. Creation/replacement commits atomically after validation, texture resolution, and backend creation succeed. Descriptor slices are borrowed for the call only. Backends own their retained shader data. Game components retain authored definitions for recreation, never serialized runtime handles.

Catalog keys must be registered images. A cold registered image is acquired automatically; `TextureNotReady` asks the caller to retry on a later frame. One pending pin is retained per entity/binding across retries, even when scene asset inference did not request the image. Successful creation transfers ownership to committed pins and sweeps the entity's pending requests. Superseding a pending binding releases its old request only once the replacement request is secured, without canceling other bindings. A failed create or texture update — `TextureNotReady` included — drops nothing the entity already held: the previous material and every pending request survive until a later attempt commits, the binding is superseded, or the material is cleared. Clear, entity destruction, scene reset, world destruction, and shutdown release all pending and committed pins. `AssetLoadFailed`, `AssetDecodeNotQueued`, `AssetNotRegistered`, and invalid descriptors are actionable failures, not indefinite readiness waits. Unsupported renderers return `Unsupported`.

A direct `TextureId` is borrowed; its original owner remains responsible for its lifetime. Gfx resolves registry ids to backend ids. Unloading, invalidating, or replacing a bound texture invalidates dependent materials before the backend texture slot is recycled. Subsequent setters return `InvalidHandle`; the game facade clears the stale entity binding so the component can recreate it. An invalidated material does not submit its old shader; the sprite uses the plain draw path.

Named shelved worlds preserve their own materials and pins. Scene reset and actual entity deletion destroy them. `surfaceLost` invalidates catalog GPU resources first, then FORGETS every world's runtime materials through the renderer's `invalidateShaderMaterials` (labelle-gfx#361) — no backend destroy ever runs against the lost context, and a texture-less material is retired here rather than left to per-texture invalidation. Pins are released, bound sprites fall back to the plain draw path, `shaderMaterial(entity)` becomes null, and the engine logs a warning with the count so the fallback is never silent. Once the surface is restored, game systems recreate from their own definitions; cold catalog resources are requested again automatically. Calls while the GPU is unavailable return `GpuSurfaceUnavailable`.

JSONC and `.zon` authored sprite materials cannot install a live shader id. Effects are authored as game-owned components and create materials only at runtime. Explicit `clearMaterial` and `removeSprite` release owned shader resources; the engine tick also reaps raw ECS removals.

Validation:

- `zig build test-shader-material`: executed shader API/lifecycle tests with recording renderers and the real asynchronous asset catalog.
- `zig build test-shader-regressions`: shader tests plus scene lifecycle, prefab refresh, deserialization, and existing material tests.
- Gfx: `zig build test` includes typed texture resolution, draw dispatch, unsupported backends, stale ids, and texture replacement invalidation.
