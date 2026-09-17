# Implementation plan: COND-07 pixel-water material

Status: proposed, not implemented. Design: [RFC-PIXEL-WATER.md](RFC-PIXEL-WATER.md).
Tracking: [BGFX #100](https://github.com/labelle-toolkit/labelle-bgfx/issues/100).
Deferred general shader system: [engine #878](https://github.com/labelle-toolkit/labelle-engine/issues/878).

## Delivery strategy

Deliver the actual condenser as a vertical slice, using a built-in material and supplied reflection texture. Work proceeds core contract → gfx retention/BGFX draw → engine authoring/runtime → complete example. No arbitrary shader loading is on the critical path. Use separate, linked PRs in affected repositories; do not land dependency pins before their upstream commits are available.

## 1. Lock the binding contract and baseline

Repositories: labelle-core, labelle-gfx, labelle-bgfx, labelle-engine; inspect generated backend adapters in the CLI and other backend implementations.

- Record the current material draw signatures, Material layout, serializer behavior, capability enum switches, shader build targets, texture sampling and resource ownership.
- Define PixelWaterDraw and the minimal optional typed draw API. Choose the retained water-instance reference representation and generation checks. Keep ordinary sprite payloads small.
- Add pixel_water as the capability identity. Enumerate every exhaustive switch affected, including Sokol/null/mock and generated wrappers; unsupported implementations must still compile.
- If any ABI layout changes, enumerate size/offset assertions and adapter/version/pin changes before implementation. Do not silently expand an extern struct across differently pinned packages.
- Capture the existing material/post-fx golden baselines. Existing BGFX targets include `zig build material-golden` and `zig build post-fx-golden`; run on supported hardware with the repository's pinned toolchain.

Exit: reviewed schema/signatures, ownership table, compatibility matrix and baseline results. This is the RFC's one binding-design gate; it does not reopen whether to build a general shader system.

## 2. Prepare the real condenser assets

Example/art work, coordinated with #100:

- Use the reference GIF linked in the RFC. Preserve the approved reference separately.
- Choose/document the working native art grid and the reservoir's logical bounds; the enlarged scene's six-screen-pixel cell is not a fixed native resolution.
- Prepare machine interior/frame, maximum-fill reservoir mask, static fallback, supplied reflection texture, drops and independently animated mist.
- Keep foreground cooler/cabinet and other occluders separate. Complete hidden reservoir artwork only where necessary and mark reconstructed layers.
- Record anchors, local surface coordinates and drop emitter positions. Export transparent PNGs and retain editable layered sources.

Exit: a static layered condenser reconstruction with correct occlusion, checked at native scale and integer enlargement. Do not use a full-room GIF as the only runnable asset.

## 3. Core and retained renderer plumbing

Likely files: core `src/backend_contract.zig`; gfx `src/retained_engine.zig`, retained sprite/material state and material dispatch; associated adapters and mocks.

- Add typed parameter definitions, capability checks and optional draw forwarding agreed in phase 1.
- Implement allocation/update/release of retained water instances; reject stale instance references safely.
- Bind mask/reflection via existing asset texture handles; preserve shared ownership.
- Carry state snapshots to draw submission. Time/ripple changes must refresh uniforms without requiring a transform change or re-creating GPU resources.
- Define fallback dispatch and once-only diagnostics for unavailable programs/resources.

Tests: old effects unchanged; absent optional draw supported safely; invalid/stale instance IDs; two independent reservoirs; updates visible when material identity is stable; release/reuse without shared texture destruction; generated contract/adapter checks.

Exit: mock-backed water draws contain the expected data and ordinary sprites retain their existing fast path.

## 4. BGFX shader and draw path

Likely files: `src/gfx/texture.zig`, `src/gfx/programs.zig`, `src/shaders/`, shader packaging/build inputs, capability exports and material golden harness.

- Add and compile the water shader using existing BGFX tooling. Verify Metal first; list other compiled/verified targets explicitly.
- Implement fixed mask/reflection samplers with clamped nearest sampling and documented uniform layout.
- Add mask/level clipping, dark water body, limited highlights, periodic surface motion and supplied reflection sampling.
- Quantize logical sampling/displacement. Test zero amplitude and a one-native-pixel displacement.
- Add eight bounded ripple inputs, local falloff and time-based fade. Ensure age outside the active interval contributes nothing.
- Preserve blending, sprite source rectangles, transform and layer order. Never read and write the same render target; v1 does not need a scene-capture pass.
- Create/destroy the effect's programs and uniforms independently. Check handles and degrade only this effect on failure.

Visual tests: level 0/0.35/1; waves off/on; ripple start/mid/expired; edge impacts; masked-out pixels; two materials; native/2x/4x nearest scaling; foreground occlusion. Existing material goldens must pass. Add a dedicated fixed-time water capture rather than silently re-blessing regressions.

Exit: the GPU effect works in a small fixture, with resource cleanup and supported-target reporting checked.

## 5. Engine authoring and runtime controls

Likely files: `src/game/visuals.zig` or a focused water helper/mixin, a typed PixelWater component, existing JSON/ZON component coercion and asset lifecycle integration. Extend `test/set_material_test.zig` or add focused water tests.

- Register typed PixelWater settings through the existing component/prefab authoring path. Do not create a parallel JSON parser.
- Resolve mask/reflection assets and create the retained instance when the entity is ready; release it on destruction/reload.
- Implement proposed setWaterLevel/addWaterRipple helpers and deterministic simulation-time updates.
- Apply configuration validation from the RFC, with entity/field-specific diagnostics.
- Bound impacts to eight; expire old entries and replace the oldest deterministically at capacity. Clear ripples when the level changes. Handle empty reservoirs and invalid/outside impacts.
- Add droplet crossing logic in the example/game behavior; emit one ripple per hit and retire/reset the droplet. Keep mist animation independent.

Tests: JSON/ZON equivalent settings; missing textures; non-finite/range errors; pause/time-scale behavior; exact capacity/expiry; no duplicate impact; entity cleanup/reload; dirty-state propagation; unsupported renderer fallback.

Exit: game code can change level and trigger impacts without BGFX-specific calls.

## 6. Integrate and review COND-07

- Assemble the prepared machine in a runnable Labelle example with the real reservoir bounds and emitter positions.
- Start with amplitude/distortion ≤1 logical pixel and subdued reflection opacity. Match the dark palette before adding detail.
- Expose a small example control panel or key bindings for pause, single impact, water level and waves on/off. This is a review aid, not a required engine editor feature.
- Verify drops meet the current surface and cause ripples at the matching local X coordinate; mist remains above the reservoir.
- Capture a native image, integer-upscaled image and short real-time clip. Compare against the attached condenser reference, checking unchanged frame/foreground and coherent water motion.
- Check a sustained run for shader/program churn, leaked resources, repeated diagnostics and unbounded impact growth. Record frame/draw cost on the test machine; do not promise an unmeasured budget.

Exit: #100's condenser-specific acceptance criteria are met. A generic shader demo alone is insufficient.

## 7. Release and documentation

- Land core contract and adapter support, then renderer/backend changes, then engine bindings and example with compatible pins. Use integration branches until the complete chain builds.
- Publish the final authored schema, coordinate/color conventions, pause behavior, impact limit, sampler requirements, platform matrix and fallback semantics.
- Document that changing material settings needs no backend change, but adding an unrelated shader effect still does until #878 is implemented.
- Attach validation results and the condenser capture to #100; close it only after the runnable scene is delivered.

## Risks and stop conditions

- Contract mismatch: stop pin updates until layout/adapter checks agree.
- Incorrect native grid or mask: resolve the asset coordinates before tuning shader noise.
- Frame/background distortion: verify mask and layer ordering before reducing effect opacity to hide it.
- Unsupported renderer: use the explicit fallback; never advertise unverified support.
- Scope growth into custom shader loading, live scene reflections or fluid physics: file follow-ups and keep this delivery bounded.
