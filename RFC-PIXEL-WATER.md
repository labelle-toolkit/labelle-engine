# RFC: Built-in pixel water for the COND-07 condenser

Status: proposed; documentation and implementation plan only.

Implementation objective: [labelle-bgfx#100](https://github.com/labelle-toolkit/labelle-bgfx/issues/100).
Broader custom-material design: [labelle-engine#878](https://github.com/labelle-toolkit/labelle-engine/issues/878) (backlog; not a dependency).
Detailed delivery plan: [RFC-PIXEL-WATER-PLAN.md](RFC-PIXEL-WATER-PLAN.md).

## Problem and outcome

Animate the actual COND-07 condenser in Labelle using BGFX. Its bottom is a liquid-water reservoir, with independently drifting mist above it. Drops must hit the current water surface, trigger fading ripples, and disturb reflected light. Keep the machine frame, coils and foreground occlusion stable.

![Condenser reference](https://raw.githubusercontent.com/labelle-toolkit/labelle-bgfx/6a1ce3a24f42adf75b41dec81ec33921b6a27918/docs/issue-references/condenser-100/condenser-detail.gif)

The reference already has animated drops and mist. It does not yet demonstrate reactive reservoir water. A generic shader rectangle is useful for testing but is not the final deliverable.

## Decision

Implement one curated, built-in `pixel_water` effect first. Author settings in the game's existing declarative scene/prefab pipeline; implement GPU behavior in `labelle-bgfx/src/shaders/`. Keep asset references and game parameters backend-independent. Runtime game code supplies time, level and impact events.

This extends the existing built-in material approach. It does not add arbitrary game shader files, a general uniform-reflection system, a material graph, shader hot reload, or a new JSON file loader. A separate JSON material library can be designed later; the example below describes a proposed component value, not a currently supported API.

## Existing implementation

- `labelle-core/src/backend_contract.zig` owns the fixed MaterialEffect enum and flat extern Material/MaterialUniforms contracts.
- Existing effects are palette_swap, flash, dissolve and outline. Water has no current effect entry.
- `labelle-engine/src/game/visuals.zig` exposes setMaterial/clearMaterial and marks retained visuals dirty. Sprite.material already supports declarative authoring.
- `labelle-gfx` carries retained sprite state and forwards material-aware draws.
- `labelle-bgfx/src/gfx/texture.zig`, `programs.zig` and `src/shaders/` implement backend material draws and programs. Programs are initialized lazily and gated individually.
- BGFX already has offscreen render-target and post-effect infrastructure. Live scene capture is unnecessary for the first water implementation.

The current MaterialUniforms layout is insufficient for water plus several ripple events. Do not overload palette/dissolve fields or interpret aux_texture as an unrelated CPU pointer. Extending shared layouts requires a coordinated adapter/layout audit and dependency updates, even if Zig source defaults preserve existing call sites.

## Proposed authoring model

Attach a typed `PixelWater` configuration to the reservoir sprite through the existing component loader. An engine helper resolves resources and attaches the built-in material at runtime. Use existing sprite tint/transform/z-order conventions. The component name and helper signatures below are proposed.

```json
{
  "PixelWater": {
    "mask": "condenser/reservoir_mask.png",
    "reflection": "condenser/reflection.png",
    "logical_size": [96, 18],
    "grid_pixels": 1,
    "water_level": 0.35,
    "deep_color": "#172D36",
    "surface_color": "#507B8B",
    "highlight_color": "#ADCAC6",
    "wave_amplitude_pixels": 1,
    "wave_period_seconds": 3,
    "reflection_opacity": 0.25,
    "distortion_pixels": 1,
    "ripple_duration_seconds": 0.8,
    "ripple_radius_pixels": 6,
    "ripple_strength_pixels": 1
  }
}
```

The 96x18 size is illustrative, not a measured extraction. Determine the actual reservoir grid while preparing the asset. Asset identifiers above use illustrative names; resolve them through the project's existing asset conventions, not arbitrary filesystem access from a shader.

Validation: positive integer logical dimensions and grid size; finite values; level and opacity in [0,1]; positive wave/ripple durations and radius; nonnegative amplitudes. Reject invalid authored values with the component/entity and field named. Runtime level updates may clamp to [0,1], but reject NaN/Infinity. Parse hex colors as sRGB authoring values and convert consistently with the backend's existing color pipeline; avoid double gamma conversion.

## Units, sampling and reservoir mask

- Local coordinates are in native art pixels, origin at the reservoir rectangle's top-left; +X right and +Y down.
- Water level is the fraction filled from the rectangle's bottom: surface_y = height * (1 - level).
- The mask defines the maximum interior silhouette. Level clipping happens inside that silhouette; zero level renders no water and accepts no impacts.
- Six screen pixels per effect cell belong to the enlarged reference, not the shader contract. Use the art's logical grid and integer enlargement.
- Evaluate texture/noise positions at logical cell centers; quantize displacement to grid increments. Use nearest/clamped sampling on supplied standalone textures. Initial distortion is at most one logical pixel.
- Reflection texture coordinates are reservoir-local. The supplied texture is already authored as the desired reflection; do not silently flip or capture the whole scene. Do not reflect foreground characters or the cooler.
- The v1 mask and reflection are standalone textures to avoid atlas-edge sampling. A sprite's atlas rectangle still needs correct UV handling if its base texture is packed.

## Runtime state and API

Configuration holds authored defaults. Per-instance state holds the current fill level, accumulated simulation time and up to eight active impacts. Proposed game helpers:

```zig
// Illustrative signatures; adapt to the engine's entity/resource conventions.
g.setWaterSettings(reservoir, settings); // validated waves, distortion, reflection and colors
g.setWaterLevel(reservoir, 0.45);
g.addWaterRipple(reservoir, local_x, strength);
```

The engine update step advances time from simulation delta, so pause and time scale apply. Do not derive deterministic tests from a wall clock. Drop behavior determines when its trajectory crosses the current surface and emits one impact; the shader does not detect collisions.

Runtime `strength` is a DIMENSIONLESS magnitude in [0, 1] that scales the authored `ripple_strength_pixels`; it is not itself a pixel amplitude and it is not signed. That split keeps one place to retune the effect's visual scale (the authored setting) while a drop reports only how hard it landed, and it bounds the shader's displacement by construction: peak displacement is at most `ripple_strength_pixels`, whatever a caller passes. For v1, reject impacts with non-finite values, strength outside [0, 1], X outside [0, logical_width), or an empty reservoir. CPU validation is limited to logical bounds: it does not query mask coverage. The GPU mask clips ripple output, so an in-bounds impact inside a masked-out region may consume a ripple slot without producing visible output. The image loader releases decoded CPU pixels after upload; no CPU collision-mask retention or GPU readback is introduced. Author condenser emitters over valid surface coverage. A future irregular-reservoir collision feature would require an explicit CPU coverage asset and lifetime contract. Expire ripples after their configured duration. When all eight slots are occupied, replace the oldest active impact deterministically. Store x, start time and strength; the surface defines y. Test negative, above-one and non-finite strengths at BOTH boundaries — the authored `ripple_strength_pixels` and the runtime `addWaterRipple` — since a bound enforced on only one of them leaves the other as the way to exceed it. Each reservoir owns its own state, with no cross-instance ripple leakage. Nonzero level changes preserve each active ripple's X, age and strength; the shader evaluates it relative to the current surface_y on every draw. This keeps disturbances attached to the rising surface while the condenser fills. Setting the level to zero clears active ripples; refilling starts without old impacts. Test continuous filling during repeated impacts, abrupt nonzero level changes, emptying and refilling.

Expose PixelWater and its public settings type through src/root.zig, following the existing built-in component exports.

setWaterSettings validates a complete backend-independent settings value and atomically updates the component and gfx-owned retained instance. It covers wave amplitude/period, distortion, reflection opacity, color ramps and ripple appearance. Unchanged values are a no-op; changed values bump the retained revision and become visible on the next submission even when the transform/material identity is unchanged. Invalid values leave the previous settings intact. Changes preserve simulation time and active impacts; ripple appearance settings take effect on their next evaluation. Changing wave period may shift phase in v1. Texture references, logical dimensions and grid size are structural configuration: change them through explicit reconfiguration/recreation with resource validation, not this scalar settings setter.

Direct field mutation is not an automatic synchronization mechanism. Runtime callers must use the setter; loader/editor/hot-reload paths must invoke the same validated synchronization operation. Order matters: validate and STAGE the candidate settings before committing EITHER side. Committing the component first and synchronizing after leaves a torn state when validation rejects the candidate — the component holds the new value while the gfx-owned instance still holds the old one, and nothing is left to detect the divergence because the component already looks updated. Validate the candidate, then commit component and retained instance together; if that is not structurally possible on a path, restore the component's previous value when synchronization rejects. A rejected update must leave BOTH sides on the previous settings. Changing settings must not create a new GPU program or silently recreate the water instance.

A water API update must invalidate the relevant retained data. Animated time/ripples must be uploaded even if the entity transform and material identity are unchanged.

## Shared draw contract and lifetime

Propose a typed PixelWaterDraw value with resolved mask/reflection texture handles, logical dimensions, grid/level/time, color ramps, wave parameters and a fixed eight-entry ripple array plus count. Use explicit flat extern-compatible fields at generated adapter boundaries; do not introduce unversioned pointers or implicit union layout assumptions.

Keep the large per-instance payload out of every ordinary sprite's inline MaterialUniforms. A gfx-owned water-instance store can hold it, addressed by a checked generational instance ID. The engine owns the entity-to-instance association; gfx owns retained draw state; the backend owns GPU programs/uniform handles. Shared texture ownership remains with the asset manager. Destroying a water instance must not destroy a shared texture.

The first implementation phase must settle and record the smallest typed binding extension: a water instance reference on retained visual state and an optional water-aware draw operation, with MaterialEffect.pixel_water as the capability identity. Keep existing effects' layouts unchanged where possible. If the chosen approach changes a shared ABI, explicitly update generated adapters/layout assertions and pinned dependencies together. Do not claim optional capability support alone makes a layout change compatible.

This is a single built-in effect-specific path, not the game-authored shader API in #878. That broader design can later reuse the effect's domain settings without guaranteeing compatibility with this internal binding layout.

### Resolved in phase 1 (labelle-core#78)

The smallest typed binding extension, now landed and layout-locked:

- `MaterialEffect.pixel_water`, APPENDED (tags 0..4 unchanged), is the capability identity.
- The payload rides its own optional decl `drawTextureProPixelWater(texture, source, dest, origin, rotation, tint, water: PixelWaterDraw)`. `MaterialUniforms` is byte-identical: no shipped effect's layout moved, and an ordinary `.none` sprite pays nothing.
- `PixelWaterDraw` is passed BY VALUE as a flat `extern struct` — 256 bytes laid out as 16 vec4s with the u32 header first. This resolves the RFC's open choice in favour of the value over a generational instance reference AT THE BACKEND SEAM: no pointer and no handle-table identity crosses the assembler-generated marshal boundary between differently-pinned packages, which is exactly the hazard this section warns about. The gfx-owned instance store still exists — it is where the engine's per-entity state lives and where the payload is assembled — but it stops at the gfx side of the seam.
- `PIXEL_WATER_MAX_RIPPLES = 8` is a fixed array rather than a slice, both to keep the value flat and to give the shader's ripple loop a comptime trip count, which ESSL 3.00 / WebGL2 need.
- Support is NOT implied by declaring `drawTextureProMaterial`. `pixel_water` is the one effect additionally gated on its own decl, in both `materialCapabilities` and `Backend(Impl).materialSupported`; without that, every backend predating this sub-surface would advertise water it cannot draw. Unsupported degrades to a plain `drawTexturePro` — the authored static-reservoir fallback.
- Purely additive and `@hasDecl`-gated, so `DRAW_CONTRACT_VERSION` does not bump and no existing backend is rejected.

Downstream `MaterialEffect` switch audit for the pin bump: labelle-sokol (5 sites in `src/gfx/material.zig`) and labelle-bgfx (3 in `src/gfx/texture.zig` plus `programForEffect`) need `.pixel_water` arms; labelle-gfx only in `test/material_batch_cost.zig`; raylib / sdl / wgpu / null have no material switches and are unaffected.

## BGFX implementation

Add the pixel-water fragment shader to the existing shader build/package pipeline with all four packaged variants: Metal (_mtl), SPIR-V (_spv), ESSL 3.00 (_essl), and desktop GLSL (_glsl). Match the existing renderer selection, including OpenGLES for WebGL2 and Android. All four must compile and be packaged; Metal macOS, WebGL2 and Android OpenGLES are required runtime delivery checks. SPIR-V/Vulkan and desktop GLSL runtime results must be reported explicitly, separately from compile-only coverage. Use the established sprite vertex convention and premultiplication/blend conventions. Resolve fixed sampler slots for mask/reflection and upload typed uniforms; document every slot and color-space expectation.

Compute a restrained periodic surface wave, add bounded fading ripple disturbances, quantize offsets, sample the supplied reflection, and mix the water's dark/body and limited highlight colors. Clip all output to both mask and fill level. A highlight is not physically simulated light; reflection opacity/highlight intensity may be driven by game lamp state.

Preserve draw order: machine interior, water, independent mist, drops/splashes as appropriate, glass/frame and foreground occluders. Verify the actual condenser composition rather than imposing one order on every asset.

Initialize programs independently from existing effects; failure must not disable palette/outline/etc. Cache resources, release all owned handles, and avoid per-frame shader creation. Reuse existing submission machinery where possible; do not add a full-screen pass solely for this reservoir.

## Capabilities and fallback

BGFX is the first supported backend. Metal on macOS can be the first development checkpoint, but delivery also requires working WebGL2 and Android OpenGLES rendering, not their silent static fallback. Shader compilation targets and renderer support must be explicitly advertised based on real program readiness. Other backends remain compilable and report pixel_water unsupported until implemented.

On unsupported capability or missing GPU resources, draw an authored static reservoir fallback with ordinary sprite rendering and report a diagnostic once per relevant failure. The fallback is deliberately approximate; do not claim its level/ripples are simulated. Invalid authored assets should fail validation with useful diagnostics instead of disappearing silently.

## Acceptance and non-goals

Done means a runnable example uses this condenser's artwork, with drops hitting the visible water level, localized fading ripples, subtle reflected light, separate mist, and stable foreground/frame pixels. Include native/integer-scaled captures and deterministic state/visual tests, plus configuration and fallback documentation.

Not included: fluid simulation, live scene reflections/refraction, arbitrary shaders, all-backend visual parity, a general material editor, or a general material JSON library. Existing reference imagery is scene-composited: preparing the reservoir mask, reflection and occlusion layers is part of delivery, not an already completed extraction.

## Alternatives

- Baked sprites alone preserve appearance and remain a fallback, but do not provide responsive water.
- General custom-shader support would avoid future backend edits but adds build, validation, binding and portability scope; track it in #878.
- Adding GPU behavior directly to game code would bypass the intended backend boundary and make reuse harder.
