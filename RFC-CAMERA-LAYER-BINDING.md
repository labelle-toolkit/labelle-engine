# RFC: Camera-Bound Layers

**Issue:** labelle-toolkit/labelle-engine#723  
**Status:** Draft  
**Author:** Alexandre  
**Date:** 2026-07-08 (rev 2, 2026-07-09 — verified architecture across gfx/engine/backends; rev 3 — default-camera invariant; rev 4 — review findings: reset-then-seed, `getCameraByTag`, tag serde, minimap boundary)

## Problem

The camera-prefabs MVP (#714) made cameras first-class entities — you can author a `Camera` component, seed it on load, and manipulate it. But a layer cannot choose *which* camera transforms it: world layers follow **the** camera, screen layers follow none.

`LayerConfig.space` (labelle-gfx `src/layer.zig:20`) conflates two orthogonal axes:

1. **Whose transform applies?** — `.world` → the active camera; `.screen` / `.screen_fill` → none (pinned).
2. **Fit or fill?** — `.screen_fill` stretches to the framebuffer; `.screen` / `.world` aspect-fit.

Because "which camera" is welded to "world vs screen," a game cannot:

- give a backdrop its own slower-panning camera (**parallax**);
- point a minimap / picture-in-picture layer at a **second camera**;
- decouple a pinned HUD from a world that follows the gameplay camera, except by leaning on the implicit `.screen` behavior.

**Concrete case — the Flying-Platform sky.** The sky (backdrop + cloud bands + sun/moon) lives on `screen` / `screen_fill` layers precisely so it does *not* pan with the world camera. That is correct for a static sky, but it also means there is no way to give the sky *depth* — clouds that drift slightly against the platform as the camera moves — without hand-rolling the offset math in a script. Parallax "wants" to be "this layer follows a camera that tracks the main one at a fraction," and today there is no seam to express that.

## Verified current architecture (investigation, 2026-07-09)

The surprising finding: **labelle-gfx already ships a multi-camera renderer.** The gap is (a) the engine only ever drives one slot, and (b) layers cannot choose a camera. Verified seams, with file:line:

### labelle-gfx — multi-camera exists

- **4-slot camera pool.** `CameraManager` (`camera/src/root.zig:375`) pre-allocates cameras 0–3, activated via a bitmask: `setActive(index: u2, active: bool)` (`:447`), `activeIterator()` (`:498`), `setupSplitScreen(layout)` presets (`:459`).
- **Camera-outer render loop.** `render()` (`src/renderer.zig:525-537`) iterates active cameras; each pass calls `applyViewport(cam)` then `renderThroughCamera(cam)` (`:543-583`), which walks **all** layers, wrapping world layers in `cam.begin()`/`cam.end()` and toggling `setApplyFit` for `screen_fill` (split-screen, labelle-gfx#226).
- **Cull rect is already the union of all active cameras.** `applyCullViewport()` (`src/renderer.zig:436-496`) accumulates every active camera's rotation-expanded viewport AABB into one rect. So multi-camera culling is already *correct by over-approximation* — per-camera culling is an optimization, not a correctness requirement.
- **Camera wrapper.** `CameraWith` (`camera/src/root.zig:94-363`) holds `x, y, zoom, rotation, bounds, screen_viewport: ?ScreenViewport`; `begin()` → backend `beginMode2D(toBackend())`, `end()` → `endMode2D()`.

### labelle-engine — single-camera bottleneck

- **First-match-wins seeding.** `seedCameraFromComponent` (`src/game/camera_mixin.zig:34-49`) views `{Position, Camera}` and **returns after the first entity**; extra `Camera` entities are silently inert. Seeded at scene load (`scene_mixin.zig:534`, `:712`), hot reload (`loop_mixin.zig:187`), and apply-while-paused (`editor_api.zig:143→414`).
- **`game.getCamera()` is hardwired to slot 0** (`misc_mixin.zig:165` → `renderer.getCamera()`). `getCameraManager()` is forwarded (`misc_mixin.zig:168`) but no engine logic populates or queries slots 1–3.
- **`Camera.viewport` is declared but inert** (`src/camera.zig:20-23`): *"carried now so the deferred multi-camera work (split-screen / minimap / PiP) is purely additive."* RFC-CAMERA-PREFABS explicitly deferred *"mapping N Camera entities onto the N manager slots"* — this RFC is that follow-up.

### Backends — viewport clipping is test-only

- `applyViewport` (`src/renderer.zig:505-518`) calls optional backend hooks `setViewport`/`clearViewport`. **Only the MockBackend implements them** (`src/mock_backend.zig:535,547`). bgfx, sokol, and raylib all lack them — on real backends multiple active cameras today would overlay full-window. Parallax needs no viewports; minimap/split-screen do (Phase 2 backend work).

### labelle-assembler — layer codegen

- `generateGameLayers` (`src/codegen/main_template.zig:492-509`) emits each layer's `config()` arm as `.{ .order = N, .space = .X }` from `project.labelle`'s `.layers` list. A `.camera` field is a one-line conditional emit; projects that author no binding produce **byte-identical** output.

## Proposal

Introduce a **per-layer camera binding by tag**. A layer names a camera tag; `Camera` entities carry a tag; the engine assigns tagged cameras to manager slots; the renderer resolves tag → active camera per layer. No tag = today's behavior.

### The default camera (invariant)

Slot 0 of the gfx camera pool is the **default camera**: always allocated, always active, implicitly tagged `"main"`. It exists whether or not the scene authors any `Camera` entity — exactly as today, where `game.getCamera()` returns slot 0 and imperative drivers (FP's `camera_control`) work without any authored camera. An authored `Camera` entity tagged `"main"` **configures** the default camera (the existing #714 seed path); it never creates or replaces it. Cameras with other tags are *additional* cameras in slots 1–3, and slot 0 is **reserved** — a scene authoring only a `"sky_parallax"` camera must not capture slot 0, or `getCamera()` would silently return the parallax camera.

Consequences: a game with zero `Camera` entities renders identically to today; `"main"` bindings always resolve; authored cameras stay pure opt-in configuration, which keeps the simple case simple.

### Authoring surface (`project.labelle`)

```zig
.layers = .{
    .{ .name = "background", .order = 0, .space = .screen_fill },
    .{ .name = "sky",        .order = 1, .space = .screen, .camera = "sky_parallax" },
    .{ .name = "world",      .order = 2, .space = .world },   // implicit "main"
    .{ .name = "ui",         .order = 3, .space = .screen },  // pinned
},
```

### `LayerConfig` (labelle-gfx `src/layer.zig`)

```zig
pub const LayerConfig = struct {
    space: LayerSpace = .world,
    order: i8 = 0,
    visible: bool = true,
    /// Camera tag this layer is transformed by. `null` = default:
    /// `.world` layers bind the reserved "main" tag; screen layers are
    /// pinned. A non-null tag on a screen-space layer OVERRIDES pinning
    /// (that is the parallax case); `space` keeps only fit semantics.
    camera: ?[]const u8 = null,
};
```

### `Camera` component (labelle-engine `src/camera.zig`)

```zig
pub const Camera = struct {
    zoom: f32 = 1.0,
    viewport: ?Viewport = null,
    /// Layers whose binding equals this tag are transformed by this camera.
    tag: []const u8 = "main", // storage: bounded/interned — see note
};
```

**Tag storage & serde (implementation note).** `Camera` deliberately has no string fields today — `applyCameraComponentJson` (`camera_mixin.zig:88`) parses patches with a transient call-scoped arena, so a heap `[]const u8` would dangle. But the tag vocabulary is **comptime-closed**: it is exactly the set of tags authored in `project.labelle` layer bindings, plus `"main"`. So the component stores a bounded inline buffer (`[16:0]u8`) or an index into the comptime tag table — never an allocated slice — and validation against the vocabulary happens at seed time. The built-in Camera channels must round-trip the tag: save/load serde, the studio digest (`camera:{zoom,viewport?,view}` → gains `tag`), and the `editor_set_component` bridge (contract bump alongside the field).

### Engine seeding: first-match → all-matches (slot 0 reserved)

`seedCameraFromComponent` becomes a **reset-then-seed** pass. It first deactivates slots 1–3 and clears the tag map (slot 0 / `"main"` untouched) — otherwise a camera removed by a scene change or reload would leave a stale active slot that bound layers keep rendering through. Then it iterates **all** `{Position, Camera}` entities (drop the early `return` at `camera_mixin.zig:47`):

- **tag `"main"`** → configure slot 0 (position/zoom — the existing #714 behavior). First `"main"` wins; extras warn once (multi-`"main"` authoring = split-screen, Phase 3).
- **other tags** → next free slot 1–3; seed position/zoom from the entity (`getWorldPosition` + `Camera`), record `tag → slot`, mark active.
- **zero matches** → done. The default camera in slot 0 remains, at its current state (defaults, or wherever an imperative driver put it). No `Camera` entity is ever required.

Reseed triggers: the existing three (scene load `scene_mixin.zig:534/:712`, hot reload `loop_mixin.zig:187`, apply-while-paused `editor_api.zig:143`) **plus `loadGameState`** — the save-load path reattaches `Camera` components without any seed call (`save_load/load.zig:584-610`), so tagged cameras in a save would otherwise come back with dead slots.

### Driving secondary cameras: `getCameraByTag`

`game.getCamera()` stays = slot 0 = the default camera, unconditionally. But seeding alone cannot animate a parallax camera — seeds only fire on load/reload/paused frames, and nothing syncs `Camera` components during unpaused gameplay (by design: #714's soft-ownership means the component is the authored *seed*, not a per-frame driver). Secondary cameras get the same contract via one new accessor:

```zig
game.getCameraByTag("sky_parallax")  // → ?*CameraType (the gfx slot camera), null if unseeded
```

Gameplay scripts drive the returned slot camera imperatively — the parallax follow script is then really three lines: read `getCamera()` (main), compute the fractional target, `setPosition` on `getCameraByTag("sky_parallax")`. The component is not written back, mirroring how `camera_control` drives the main camera today.

### Render loop: layer-outer, camera-inner (the load-bearing change)

The current loop is camera-outer (`for cam: for layer`). Merely *filtering* layers per camera inside it would break z-order: a layer bound to a later slot would draw **after** — i.e. on top of — higher-order layers bound to earlier slots (sky-over-world). The loop must invert for binding semantics:

Resolution targets the **gfx pool camera** (the slot), which carries the full transform — position seeded from the entity's `Position`, then driven imperatively via `getCameraByTag`. The engine `Camera` *component* is never dereferenced at render time, keeping gfx entity-agnostic.

```zig
// renderer.render(), sketch:
if (self.viewport_culling) self.applyCullViewport();  // union — unchanged
inline for (sorted_layers) |layer| {
    const binding = layer.config().camera orelse implicitTag(layer); // "main" | null
    var rendered = false;
    if (binding) |tag| {
        var it = self.camera_mgr.activeIterator();
        while (it.next()) |cam| {
            if (!cam.hasTag(tag)) continue;
            applyViewport(cam);                     // no-op w/o backend hook
            if (@hasDecl(BackendImpl, "setApplyFit"))
                BackendImpl.setApplyFit(layer.config().space != .screen_fill);
            cam.begin();
            self.inner.renderLayer(layer);
            cam.end();
            rendered = true;
        }
    }
    if (!rendered) {
        // Unbound — or bound to a tag with no active camera (missing /
        // misspelled prefab; warn once): degrade to the unbound default.
        // World layers render through the default camera (slot 0);
        // screen layers render pinned, full window.
        clearViewport();
        ...setApplyFit + (default cam begin/end for .world) + renderLayer...
    }
}
```

Two binding shapes fall out naturally:

- **Partition (parallax):** each layer binds one tag → renders exactly once, through its camera, in global layer order.
- **Fan-out (split-screen):** N active cameras sharing the `"main"` tag → every `"main"`-bound layer renders once per camera, into each camera's viewport. This preserves the #226 split-screen semantics (each viewport gets the full stack) — the interleaving across viewports differs from today's camera-outer order, but with disjoint viewports the composed result is identical, and without viewport support multiple active cameras already overlay meaninglessly.

**Unresolved tags degrade to unbound behavior.** `"main"` always resolves (the default camera in slot 0 is always active). A non-`"main"` tag with no matching active camera falls back to the layer's *unbound* default — world space → the default camera, screen space → pinned — with a one-shot debug warning. So a layer binding is a pure opt-in refinement: if the tagged camera prefab was never created (or is removed mid-development), the layer renders exactly as it did before the binding existed, never blank.

Per-(layer×camera) `begin/end`/viewport churn is a few state writes; the draw volume is unchanged.

### Culling

Unchanged for correctness: the existing union cull rect (`applyCullViewport`, `renderer.zig:436`) covers every active camera, so no bound layer's entities are wrongly culled. Optional later optimization: per-tag candidate sets, cached per frame (N grid queries for N distinct bound cameras — acceptable at 4 slots, unnecessary for Phase 1).

## Identity: why tags, not entity ids or slot indices

Layers are **comptime** (a generated `LayerEnum` from `project.labelle`); cameras are **runtime** entities; manager slots are a **runtime pool** (0–3). A comptime layer cannot hold an entity id, and authoring slot indices would leak pool mechanics into game configs and break on reordering. Tags give:

- **Cutscene / camera swap** = retag or reseed a different `Camera` entity; no layer edits.
- **gfx stays entity-agnostic**: gfx sees `tag → active camera` via the manager, never an ECS id. The engine owns entity→slot→tag assignment.
- **Assembler stays dumb**: it passes the authored tag string through verbatim; no resolution at generate time.

**Slot overflow:** slot 0 is reserved for `"main"`, so **3 slots** remain for non-`"main"` tags; a fourth tagged camera warns once and is ignored (slots are a gfx pool cap; raising it is orthogonal).  
**Duplicate tags:** the render loop's semantics are uniform — a layer renders through *every* active camera matching its tag (fan-out), and the tag map is represented one-to-many (`tag → slot set`) from day one. Phase 1 seeding keeps it simple by seeding one camera per tag (first wins + warn); multi-camera-per-tag authoring (split-screen) activates in Phase 3 without touching the loop or the map shape.

## Backward compatibility

Zero migration:

- `LayerConfig.camera` defaults `null`; `.world` layers resolve the implicit `"main"` tag; screen layers stay pinned.
- `Camera.tag` defaults `"main"`; single-camera scenes seed slot 0 exactly as today.
- **Zero `Camera` entities is a fully supported configuration** (it is FP before the camera demo): the default camera always exists in slot 0 and imperative control via `game.getCamera()` keeps working. Authoring a camera is never required.
- Assembler emits `.camera` only when authored → byte-identical codegen for existing projects.
- The loop inversion reproduces today's output for every existing configuration (one active camera ⇒ layer-outer ≡ camera-outer).

## Use cases (worked)

1. **Parallax sky** — sky layer `.camera = "sky_parallax"`; a `Camera` entity tagged `"sky_parallax"` follows `"main"` at 0.4× pan (a 3-line script, or a later built-in follow behavior). No viewports, no backend work — ships with Phase 1.
2. **Minimap** — a `minimap` layer carrying its **own content** (icons / simplified markers — the standard minimap idiom), `.camera = "overview"`; a `Camera` tagged `"overview"` with `viewport = {top-right rect}`. Needs Phase 2 (viewport activation + backend `setViewport`). Note the boundary honestly: a layer binds *one* tag, so binding a new empty layer to `"overview"` does **not** re-render the world layer's sprites into the minimap. A full world-*mirror* minimap needs either one-layer→many-tags bindings or tagging the overview camera `"main"` (which fans the entire main stack, HUD included, into the rect) — both deferred; see Open questions.
3. **Pinned HUD** — `ui` layer, no binding. Explicitly pinned regardless of world cameras.

## Phasing

- **Phase 1 — parallax (no viewports).** Three repos, all seams verified:
  - *gfx*: `LayerConfig.camera` (`src/layer.zig:20`); tag storage on manager cameras; invert `render()`/`renderThroughCamera` to layer-outer (`src/renderer.zig:525-583`). Constraint: preserve the `renderWithLayerHooks` contract — `on_before_layers` (the engine's `tilemapBackgroundHook`) must still fire once per active camera before its first world layer (`loop_mixin.zig:249-272`), so the inversion hoists a per-camera prelude rather than dropping the hook.
  - *engine*: `Camera.tag` (`src/camera.zig:38`, bounded storage per the serde note); reset-then-seed `seedCameraFromComponent` + `loadGameState` trigger (`camera_mixin.zig:34-49`); `getCameraByTag` accessor; digest/bridge round-trip of `tag`.
  - *assembler*: `LayerDef.camera` + conditional emit (`src/codegen/main_template.zig:500`).
  - Prove on FP: clouds drift against the platform via a `"sky_parallax"` camera driven by a follow script on `getCameraByTag`.
- **Phase 2 — viewports (minimap).** Activate `Camera.viewport` → gfx `screen_viewport` in seeding; implement `setViewport`/`clearViewport` in labelle-bgfx (`setViewRect`/scissor), then sokol/raylib. Today these hooks exist only in the MockBackend.
- **Phase 3 — split-screen authoring + studio.** Multiple `"main"`-tagged cameras / `setupSplitScreen` authoring; a studio gizmo to assign a layer's camera visually (extends the camera-prefab gizmo work).

## Alternatives considered

1. **Keep one global camera; fake parallax per-sprite.** Rejected — pushes camera math into game scripts and does nothing for minimap / PiP / split-screen.
2. **Bind layers to camera *entity ids*.** Rejected — layers are comptime, ids are runtime; camera swaps would force re-binding layers.
3. **Bind layers to *slot indices* (`camera: ?u2`).** Rejected — leaks the 4-slot pool into authoring; slot assignment is a runtime detail the engine should own; tags cost a 4-entry compare per layer per frame (negligible).
4. **A `parallax_factor` on layers, no camera.** Rejected — solves only parallax; "follow camera X at factor f" is already just a camera.
5. **Filter layers inside the existing camera-outer loop.** Rejected — breaks global layer z-order across camera passes (sky-over-world); this is why the loop inverts.

## Open questions

- **Pinned layers under split-screen.** Should unbound screen layers (HUD) replicate per viewport (per-player HUD, today's semantics) or render once full-window? Leaning: replicate when the camera has a viewport, once when none — matches both intuitions, needs a tie-break rule in the loop.
- **World-mirror minimap.** Re-rendering the *world layer itself* through a second camera needs one-layer→many-tags (`camera: []const []const u8`) or an overview camera tagged `"main"` + a way to exclude HUD layers from its pass. Deferred to Phase 2 design; the own-content minimap (icons layer) needs neither.
- **Follow-at-factor primitive.** Camera field, built-in behavior, or game script? Out of scope for Phase 1; the FP proof will use a `getCameraByTag` script and inform the answer.
- **Slot-pool size.** 4 is fine for the known use cases; lifting it is a gfx-internal change if ever needed.
