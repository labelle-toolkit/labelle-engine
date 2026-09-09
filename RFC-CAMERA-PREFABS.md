# RFC: Camera Prefabs

**Status:** Draft
**Author:** Alexandre
**Date:** 2026-07-08
**Tracking:** labelle-engine (this RFC) · reframes labelle-engine#564 · relates to labelle-engine#560 (RFC-UNIFY-SCENES-AND-PREFABS)

## Problem

labelle-studio treats a game as a tree of entities: it reads a scene digest, lists every entity in the Explorer, edits components in the Inspector, drags gizmos on the canvas, and round-trips the result back to `.jsonc`. This works for everything the game models as an ECS entity — sprites, prefabs, tilemaps — because those flow through the digest and the editor bridge as first-class entities.

The **camera is the one thing the studio cannot touch as an entity.** You cannot select it in the tree, you cannot edit its zoom in the inspector, you cannot drag a viewport gizmo to frame a shot, and you cannot save that framing into the scene. The camera exists, the studio can *look through* it (a free look-around override), but it is invisible to every authoring surface the studio has built for entities.

The reason is structural: the camera is **owned by labelle-gfx, not by the ECS**, and there is no `Camera` component anywhere in the engine. This RFC introduces one — a `Camera` component that makes the game camera a manipulable authored entity — while deliberately *not* disturbing the games that already drive their camera from gameplay scripts.

## Current state (what exists today)

### 1. Cameras are gfx-owned, not ECS entities

The camera lives entirely inside labelle-gfx. `labelle-gfx/camera/src/root.zig` defines `Camera` / `CameraWith` (`camera/src/root.zig:89`, `:94`) — a plain struct with `x`, `y`, `zoom` (default `1.0`), `rotation`, `min_zoom` (`0.1`), `max_zoom` (`3.0`), `bounds`, and `screen_viewport` (`camera/src/root.zig:98–105`), plus `setPosition` (`:144`), `setZoom` (`:156`), and `getViewport()` returning a world-space `ViewportRect { x, y, width, height }` (`:182`, type at `:10`). A `CameraManagerWith` owns **four** camera slots for split-screen/minimap/PiP (`camera/src/root.zig:375`), selected with `selectCamera(index: u2)` (`:435`). These are re-exported from gfx's root as `Camera` / `CameraManager` / `ViewportRect` (`labelle-gfx/src/root.zig:80–89`).

The renderer owns the manager and hands out the *active* camera: `getCameraManager()` (`labelle-gfx/src/renderer.zig:684`), `getCamera()` — the selected-or-primary camera every high-level setter routes through (`:699–704`), and `selectCamera(index: u2)` (`:710`).

None of this is an ECS entity. There is no `Camera` component, no camera row in any archetype, nothing the digest can see.

### 2. labelle-engine has no Camera component

The engine only *re-exposes* the renderer's camera type. `game.CameraType` is `RenderImpl.CameraType` when the renderer has one, else `void` (`labelle-engine/src/game.zig:1264–1266`); `game.getCamera()` forwards to `renderer.getCamera()` via `MiscMixin.getCameraImpl` (`src/game/misc_mixin.zig:165–167`). There is no engine-side `CameraComp`, and the camera never appears in `ComponentRegistry` (`src/game.zig:307`) nor in the built-in component channels.

For contrast, `Tilemap` *is* an engine built-in component (`src/tilemap.zig:16` — "Engine built-in, NOT a `ComponentRegistry` component"), applied by name in the scene loader (`src/jsonc/component_apply.zig:126–133`), saved, and published in the digest. The camera has none of that machinery. This RFC gives it the same treatment.

### 3. The studio bridge sees entities, not the camera

The engine↔studio bridge is `labelle-engine/src/editor_api.zig` — a set of `export fn editor_*` symbols the studio calls on the wasm build (bridged studio-side by `labelle-studio/src/services/preview.ts`). Three facts matter here:

- **`editor_scene_digest` publishes every `Position` entity** as `{"id":u64,"prefab"?,"sprite"?,"tilemap"?,"x":f,"y":f}` (`editor_api.zig:296–299`; per-entity assembly at `:531–563`). This is how the studio builds its tree and inspector (`preview.ts` `DigestEntity` / `parseDigest`, `:173–224`). The camera is not a `Position` entity, so **it is absent from the digest entirely.**
- **`editor_set_entity_position(id, x, y)` is the only per-component edit path** (`editor_api.zig:274–277`; `setEntityPositionImpl` at `:467–477`). There is no generic "set component" export — the studio can move an entity and nothing else.
- **`editor_set_camera(x, y, zoom)` is a look-around OVERRIDE**, not an authoring edit (`editor_api.zig:303–306`; released by `editor_release_camera`, `:310`). It is re-asserted **every frame** by `frame()` (`:130–132`, `applyCameraTo` at `:332`) specifically so it wins over gameplay camera scripts, which re-write the camera on every tick. The load-bearing comment at `editor_api.zig:41–51` spells this out: `frame` runs after the sim tick (script's camera write already down) and before `g.render()`, so the studio's override is what actually renders. It is navigation, not authored state — releasing it hands the view straight back to the game.

So today: the studio can *fly the camera around to look*, but it cannot *edit the camera as a saved entity*. That is the gap.

## Proposal

Introduce a **`Camera` component** — an engine built-in, exactly like `Tilemap` — that represents the **authored / seed** camera state. Make it flow through the same four channels every authored entity already uses: the scene-loader apply path, save/load, the digest, and the editor bridge. The result: the camera becomes an entity the studio can select in the tree, edit in the inspector, drag with a viewport gizmo, and save to the scene.

The central design decision is **soft ownership**.

### Soft ownership — the key decision

The `Camera` component is the **authored/seed** camera state. It is **not** a runtime dictator, and it deliberately **does not** take over from games that already drive their camera from a gameplay script (e.g. flying-platform-labelle's `camera_control`). Those scripts are **untouched** — we do not migrate them.

This is only coherent because of **pause semantics**. While the studio is editing, the simulation is **paused**: `editor_pause` sets the flag (`editor_api.zig:163`) that gates the sim half of the frame loop through `shouldTick` (`:116–123`), so `g.tick(dt)` — and with it every gameplay script, including `camera_control` — **does not run**. A paused camera script cannot fight the component, so while the designer edits, the component is free to be the live source of truth. On resume, the script ticks again and re-takes the wheel. The component simply stops asserting itself until the next scene load.

Three layers, each with a clear, non-overlapping job, ordered by precedence:

```
                       ┌─────────────────────────────────────────────┐
  authored / saved  →  │ 1. Camera COMPONENT   (seed + paused source) │  ← studio edits this
                       │      • seeds getCamera() once on scene load   │
                       │      • while PAUSED, applied live every frame │
                       └─────────────────────────────────────────────┘
                                          │  on resume, yields to ↓
                       ┌─────────────────────────────────────────────┐
  runtime driver    →  │ 2. Gameplay SCRIPT   (camera_control, etc.)  │  ← UNTOUCHED, not migrated
                       │      • ticks only while UNPAUSED              │
                       │      • re-asserts the camera every tick       │
                       └─────────────────────────────────────────────┘
                                          │  always overridden by ↓
                       ┌─────────────────────────────────────────────┐
  editor navigation →  │ 3. editor_set_camera OVERRIDE (look-around)  │  ← wins on top, both modes
                       │      • re-asserted post-tick by frame()       │
                       │      • released → view returns to the game    │
                       └─────────────────────────────────────────────┘
```

Why three layers instead of "the component owns the camera":

- **Layer 1 (component)** gives the studio something to author and save, and — because of pause semantics — something that renders live *while editing*, with zero risk of fighting gameplay.
- **Layer 2 (script)** is how shipping games actually move the camera (follow the player, clamp to bounds, cinematic pans). Forcing every game to express that declaratively in a component would be a migration we explicitly refuse. The component **seeds** the script's starting point; the script does the rest.
- **Layer 3 (override)** is unchanged. Look-around must win over *both* the component and the script so the designer can inspect the world from any angle without disturbing authored state — and it already does (`editor_api.zig:41–51`).

The component is a **seed, not a leash.** This is the whole reason the feature ships without touching a single game's camera logic.

### The `Camera` component shape

The camera is an entity, so its **position is its `Position` component** — the same `Position` the digest already publishes and `editor_set_entity_position` already writes. The `Camera` component carries only what `Position` doesn't:

```zig
//! Engine built-in `Camera` component — the AUTHORED / seed camera state.
//! NOT a `ComponentRegistry` component (handled by dedicated built-in
//! channels: scene loader, save/load, digest, editor bridge), exactly like
//! `Tilemap` (src/tilemap.zig). NOT a runtime dictator — see "soft ownership".
pub const Camera = struct {
    /// World→screen zoom. Seeds `getCamera().setZoom` on load; clamped by the
    /// gfx camera's `min_zoom`/`max_zoom` (camera/src/root.zig:156).
    zoom: f32 = 1.0,

    /// Optional screen-space viewport placement (split-screen / minimap / PiP),
    /// as an ENGINE-LOCAL rect type. The engine is renderer-agnostic and gfx is
    /// an optional / test-only dependency, so the component must NOT reference
    /// gfx's `ScreenViewport` — a hard reference would couple every engine build
    /// to gfx. Define a tiny engine-local `{ x, y, width, height }` mirror
    /// instead (inert in the MVP anyway). `null` = fullscreen. The single-camera
    /// MVP always renders fullscreen and ignores a non-null value; carried NOW
    /// so the deferred multi-camera work (§Deferred) is purely additive rather
    /// than a breaking component change.
    viewport: ?CameraViewport = null, // engine-local rect; NOT gfx.ScreenViewport

    // Reserved for a future declarative follow target (entity id + offset +
    // deadzone). Deferred: shipping games express "follow" in their gameplay
    // script (soft ownership), so v1 does not model it — but the shape is
    // reserved so a later `follow` field is additive, not a rename.
    // follow: ?Follow = null,
};
```

- **`x` / `y`** — the entity's **world position** (`getWorldPosition`), the camera's world center. Reuses the digest `x`/`y` and `editor_set_entity_position` verbatim — both already speak WORLD coords (§Seed sync) — so dragging the camera *is* moving an entity.
- **`zoom`** — a scalar the inspector edits and the gizmo resizes.
- **`viewport`** — a screen-space rect in an **engine-local** type (mirrors gfx's `ScreenViewport` shape at `camera/src/root.zig:30` but does **not** import it — the engine stays renderer-agnostic; gfx is an optional/test-only dep), `null` = fullscreen. Inert in the MVP; present for forward-compat with multi-camera.
- **`follow`** — reserved, not modeled in v1 (deferred; scripts own runtime follow).

Note the distinction between this **authored `viewport`** (screen-space, where the camera *renders to*, MVP: fullscreen) and the **derived world view-rect** the studio draws its gizmo from (§Digest below) — the latter is `getViewport()` (world-space, what the camera *sees*), computed from position + zoom + screen size, never stored.

### Seed-on-load + apply-while-paused sync

The component reaches the live gfx camera through the engine, never the other way around:

1. **Seed on scene load.** After a root prefab / scene is instantiated, the engine finds the Camera entity, reads its **world** position — `getWorldPosition(cameraEntity)`, **not** the raw `Position` component — and its `Camera.zoom`, and seeds the active camera once: `getCamera().setPosition(world.x, world.y)` and `getCamera().setZoom(zoom)` (`renderer.zig:699`, `camera/src/root.zig:144`/`:156`). Reading **world** coords is required, not cosmetic: the digest already publishes world position (`editor_api.zig:559` is deliberately `getWorldPosition`, with the comment at `:554–558` spelling out why) and `editor_set_entity_position` writes world coords, so the seed must read the same space. For an unparented MVP camera world == local, so this is identical **today** — but stating it now is what keeps the future `follow`-via-`Parent` direction from silently desyncing the seeded camera from what studio drew and dragged. From here the gameplay script (if any) takes over on the very first tick — the component does not fight it.

2. **Apply while paused.** While `editor_api.isPaused()` and no `editor_set_camera` override is engaged, the engine re-applies the authored Camera entity's **world position** (`getWorldPosition`) + `zoom` to `getCamera()` every frame. Because the sim is paused, the gameplay script is not writing the camera, so there is nothing to fight — and the designer sees inspector/gizmo edits **live**. This is a natural extension of the existing per-frame `frame()` pass (`editor_api.zig:130`), which already runs after the (gated) tick and before render.

3. **Override still wins.** `editor_set_camera` is applied last, unchanged (`editor_api.zig:41–51`). Look-around overrides both the authored component and the script in either mode.

On resume, step 2 stops; the script drives; the component lies dormant until the next load. This is soft ownership made concrete: **the component is authoritative exactly when — and only when — nothing else is driving the camera.**

The whole path is comptime-gated on the renderer actually having a camera, reusing the existing `gameHasCamera` gate (`editor_api.zig:326–330`: `CameraType != void` and the presence of `setPosition`/`setZoom`), so camera-less/stub renderers fold the entire feature away at compile time.

### Digest extension — publish the camera view-rect for the gizmo

Because the Camera entity has a `Position`, it **already** appears in the digest entity list once the component exists — the studio gets it in the tree for free. To let the studio *draw the viewport gizmo*, the digest gains an optional per-entity `"camera"` field, following the exact pattern the digest already uses for `prefab` / `sprite` / `tilemap` (`editor_api.zig:531–563` — an optional field emitted only when the component is present):

```jsonc
{
  "id": 7, "x": 400, "y": 300,
  "camera": {
    "zoom": 1.5,                                                  // AUTHORED field
    // "viewport": {…} — AUTHORED field, emitted ONLY when non-null (fullscreen ⇒ omitted)
    "view": { "x": 133, "y": 100, "width": 533, "height": 400 }  // DERIVED (getViewport), world-space
  }
}
```

The `camera` object publishes **both** the authored component fields **and** the derived view-rect:

- `zoom` (always) and `viewport` (only when non-null) — the **authored** component, republished so the studio can round-trip the *full* component, not just re-derive geometry. Without these a studio that only saw `view` could not reconstruct a non-fullscreen `viewport`, nor tell an authored zoom apart from a resolution artifact.
- `view` — the **derived** world-space visible rectangle from `getCamera().getViewport()` (`camera/src/root.zig:182`). This is what the studio draws as the draggable gizmo; dragging its center pans, resizing it zooms (§Studio side). Note `view` is **resolution-dependent** (`getViewport` divides the screen dims by zoom) — see the screen-size note in §Studio side.

The per-entity placement (rather than a top-level `"camera"` object) is chosen because it mirrors the existing digest grammar one-for-one and keeps the camera discoverable in the same entity sweep the tree already consumes.

### New generic export: `editor_set_component(id, name, json)`

Today the only per-component edit the bridge offers is `editor_set_entity_position` (`editor_api.zig:274`). Editing camera **zoom** — or, later, any other component field from the inspector — needs a general path. Add one export:

```zig
/// MERGE a JSON object of component fields onto component `name` of entity
/// `id` — PATCH semantics: only the provided keys are overlaid, unspecified
/// fields keep their current value (a `{"zoom":…}` edit does NOT reset
/// `viewport`). Returns 0 = ok; -1 = not bound / unknown id / component NOT
/// on the live-edit allowlist; -2 = parse/validation failure (entity
/// untouched). Buffers are copied; the caller may free them immediately.
pub export fn editor_set_component(
    id: u64,
    name_ptr: [*]const u8, name_len: usize,
    json_ptr: [*]const u8, json_len: usize,
) i32
```

- **MVP**: the allowlist contains **only `"Camera"`**. It parses the provided keys (`{"zoom":…}`, and `"viewport"` when non-fullscreen authoring lands), **merges** them onto the entity's existing `Camera` component (read current → overlay provided keys → write back), and re-seeds `getCamera()` so the paused preview updates immediately. Any other component name returns `-1`.
- **Future-proof signature, allowlist-gated implementation.** The *signature* generalizes to any component, but a component is admitted to **live** mutation only after its live-edit semantics are audited: **owned-slice replacement** (freeing the old backing memory rather than leaking it), **dirty-marking** for the render pipeline, and **transient-component safety**. This is deliberate. `component_apply.zig`'s `applyComponent` (`:71`) is a **spawn / load** path — a fresh entity, arena-allocated, with no prior state to reconcile — and **live mutation ≠ spawn-time application**: reusing it wholesale on an already-live entity would leak or corrupt owned slices. So `editor_set_component` does **not** get merge "for free" from `applyComponent`; merge is a distinct read-existing → overlay → apply per component, and each new component joins the allowlist only once that reconciliation is written and reviewed. `editor_set_entity_position` stays the audited hot-path for position drags; `editor_set_component` is the general seam the studio grows into **one vetted component at a time.**

This is the next editor-bridge contract bump (**v1.5**), following v1.1 state / v1.2 animation-def / v1.3 prefab-reload / v1.4 prefab-refresh. Like the others it is optional-on-older-builds: a studio that finds no `editor_set_component`/`camera`-digest degrades to today's behavior (no camera entity).

### Studio side

All four surfaces already exist for other entities; the camera plugs into each:

- **Tree** (`labelle-studio/src/features/Explorer.tsx`). The camera entity arrives in the digest entity list automatically. The new per-entity `camera` field tags it, so the Explorer shows it with a camera icon and lets the user select it.
- **Inspector** (`src/features/Inspector.tsx`). A Camera section: a zoom control (and a read-only world view-rect / viewport readout; a `follow` target later). Edits call `editor_set_component(id, "Camera", {…})` — live while paused.
- **Viewport gizmo** (`src/features/SceneCanvas.tsx` + `sceneCanvasDraw.ts`, projected with the existing preview camera math at `preview.ts:484–485`). Draw the digest `camera.view` world-rect as a draggable frame. **Drag the center → pan →** `editor_set_entity_position(cameraId, x, y)`. **Drag a corner/edge → zoom →** `editor_set_component(cameraId, "Camera", {"zoom":…})`. This reuses the existing drag→`editor_*` plumbing already wired for entity moves and the look-around override (`preview.ts:441`, `PlayCanvas.tsx`). The gizmo **is in v1.**
  - **Screen-size dependency (load-bearing).** The corner-drag→zoom inverse is **resolution-dependent**: `view.width = screenWidth / zoom` (`getViewport`, `camera/src/root.zig:182`/`:194`), so recovering a target `zoom` from a dragged rect width needs the **preview screen size** the digest's `view` was computed against. The MVP uses the preview canvas / design-canvas size the studio already tracks for its `PlayCamera` projection (`preview.ts:484–485`) as that source, and recomputes on canvas resize. This intersects the still-open **gfx#249** (camera does not react to a midgame resolution change): until #249 lands, a mid-session resolution change can make `view` and the live camera disagree, so the studio should treat a resize as a digest-refresh trigger rather than assume a fixed screen size.
- **`.jsonc` round-trip.** The camera is authored into the scene/prefab `.jsonc` as a normal component. The studio's scene round-tripper (`src/services/scene.ts` + `sceneJsonc.ts` / `sceneModel.ts` / `sceneWrite.ts`) already round-trips components with the **typed-model-plus-verbatim-slices** discipline that `animationDef.ts` documents in its header (`src/services/animationDef.ts:1–17` — "this follows `scene.ts`'s discipline … every non-edited byte is captured verbatim and re-emitted, so an untouched document re-renders byte-identically and editing one field yields a minimal diff"). Add `Camera` to the modeled component set so a zoom/viewport edit writes back a minimal diff and every other byte (comments, layout, sibling components) stays verbatim. Save flows through the existing save bus → `editor_load_scene` reload.

Authored form (aligned with RFC-UNIFY-SCENES-AND-PREFABS §"Camera", which already shows this shape):

```jsonc
{
  "root": {
    "components": {
      "Position": { "x": 400, "y": 300 },
      "Camera":   { "zoom": 1.5 }
    },
    "children": [ /* … */ ]
  }
}
```

## How this subsumes labelle-engine #564

labelle-engine#564 ("RFC §unification: default Camera at root-only instantiation", part of #560, label `rfc/unify-scenes-prefabs`) already calls for the engine to **insert a default `Camera` entity when the root-instantiated tree declares none**, with these rules:

- only at **root instantiation** (the state-binding entry path), never nested prefabs — prevents "two cameras when I nest a scene inside a scene";
- an explicit `Camera` component anywhere in the tree wins.

That ticket was filed **before a `Camera` component existed** — it described a mechanic with no type to instantiate. This RFC supplies the missing piece: it *defines* the `Camera` component (shape, seed/sync, save/load, digest, studio manipulability). With the component defined, #564's mechanic becomes concrete and unchanged in intent:

> **Default-camera insertion = insert a default `Camera` ENTITY** (a `Position` + a default `Camera` component) at root instantiation when the tree declares no camera. Nested prefabs and script-driven spawns do not get one. An explicit authored `Camera` wins.

**This is a runtime engine helper, not a codegen decision.** "An explicit `Camera` *anywhere* in the tree wins" **cannot** be evaluated by the assembler at comptime — whether a camera exists is a property of the *instantiated* tree (it depends on nested-prefab contents, overrides, and runtime spawns), not of the static scene source. So the engine exposes a runtime helper — `ensureDefaultCamera(rootEntity)`: scan the just-instantiated root tree and insert a default camera entity (parented under the root) **only if none exists** — and the **assembler emits a call to it** at the root-instantiation site. The assembler owns *where the call goes* (root entry path only, never nested spawns); the engine owns *whether a camera is needed* at runtime. This keeps "explicit anywhere wins" correct regardless of how the tree was assembled.

#564 is therefore **reframed under this RFC, not obsoleted** — its three rules become the acceptance criteria of the assembler ticket (§Rollout), and it aligns with RFC-UNIFY-SCENES-AND-PREFABS §"Camera — default inserted by the engine" (`RFC-UNIFY-SCENES-AND-PREFABS.md:435`), including the lifecycle detail that the default camera is parented under the state root so the `Parent` cascade tears it down with the scene.

## Goals

- The game camera is a selectable, inspectable, gizmo-editable, savable **entity** in labelle-studio.
- **Zero migration** for games that drive their camera from a script — `camera_control` and its kind are untouched.
- Authored camera state (world `Position` + `zoom`) seeds the runtime and round-trips to `.jsonc` byte-faithfully.
- The whole feature is comptime-gated to nothing on camera-less renderers.

## Non-goals

- Replacing gameplay camera scripts with a declarative component. The component is a seed; scripts remain the runtime driver (soft ownership).
- Multi-camera authoring (split-screen / minimap / PiP). Deferred (§Deferred).
- A declarative `follow` target. Reserved in the shape, not modeled in v1.
- Changing `editor_set_camera`'s look-around override semantics. Unchanged.

## Rollout — decomposed tickets

1. **labelle-engine — "Camera component + studio editor bridge (camera-prefabs MVP)."** The `Camera` built-in component (`src/camera.zig`-style module + `Game.CameraComp`, mirroring `TilemapComp` at `game.zig:229`; **engine-local** `viewport` rect, no gfx `ScreenViewport` import); the `"Camera"` branch in `component_apply.zig` (guarded `!Components.has("Camera")` like Tilemap, `:126`); **world-space** seed-on-load + apply-while-paused sync (`getWorldPosition`, not raw `Position`); save/load of `Position`+`zoom`; the digest `camera` object (authored `zoom`/`viewport` **plus** derived `view`); and the generic `editor_set_component` export (contract v1.5) — **allowlist-gated (Camera only), merge/patch semantics**.

2. **labelle-assembler — "Register Camera builtin component + default-camera-entity insertion."** Make the assembler aware of `Camera` as a built-in (so generated scene/prefab code + the component registry recognize `"Camera"`) and **emit a call to the engine's runtime `ensureDefaultCamera(root)` helper** at the root-instantiation site (root-only, never nested spawns). The engine helper does the tree scan + conditional insert (explicit-camera-anywhere-wins is a runtime property, not comptime — see §"How this subsumes #564"); the assembler owns only the call-site placement + parenting under the state root. **Reframes/subsumes labelle-engine#564.**

3. **labelle-studio — "Camera entity: tree + inspector + draggable viewport gizmo + `.jsonc` round-trip."** Tag the camera entity in the Explorer; a Camera Inspector section (zoom); the draggable world view-rect gizmo (pan → `editor_set_entity_position`, zoom → `editor_set_component`); and `Camera` in the scene round-tripper's modeled set.

4. **Comment on labelle-engine#564** that it is reframed under this RFC, linking the engine ticket + this RFC's PR.

Order: engine (defines the component + bridge) → assembler (registration + default insertion) → studio (UI). The engine ticket is the only hard prerequisite for a working preview; assembler and studio can proceed against it in parallel.

## Acceptance criteria

- A scene declaring `"Camera": { "zoom": … }` on an entity with a `Position` seeds the runtime camera on load, and the entity appears in the studio tree with a camera tag.
- With the sim paused, editing zoom in the inspector or dragging the viewport gizmo updates the rendered preview live; resuming hands the camera back to the game's script with no fight.
- `editor_set_camera` look-around still overrides both the component and the script.
- Saving writes a minimal `.jsonc` diff; an untouched scene re-renders byte-identically.
- A scene with **no** `Camera` gets a default camera entity inserted at root (only), per #564.
- A camera-less/stub renderer compiles with the entire feature folded away.

## Deferred — multi-camera authoring

The 4-slot `CameraManagerWith` (`camera/src/root.zig:375`; `selectCamera(index: u2)` at `:435`; `setupSplitScreen` / `ScreenViewport` layouts) already supports split-screen, minimap, and picture-in-picture at runtime. Authoring **multiple** camera entities — mapping N Camera entities onto the N manager slots, authoring split-screen layout, per-camera screen-space `viewport`, and `primary`/`selected` semantics (`renderer.zig:699–704`) — is deferred to a follow-up.

Rationale: the single-camera MVP proves the entire seam end-to-end (component → seed/sync → digest → edit → `.jsonc` round-trip) with one camera. Multi-camera adds slot-assignment policy, layout authoring, and per-camera gizmos — orthogonal complexity that should not gate the core manipulability the studio needs now. The component's optional `viewport` field is carried in the MVP precisely so this follow-up is **additive**, not a breaking change to authored scenes.

## Relationship to other work

- **RFC-UNIFY-SCENES-AND-PREFABS (#560)** — this RFC realizes its §"Camera" (`:435`); the Camera component is the type its default-insertion mechanic instantiates.
- **labelle-engine#564** — reframed here (see above).
- **RFC-Y-AXIS-CONVENTION** — the camera's world coordinates already flow through the project's `y_axis`; `Position`-as-camera-center inherits that convention for free (`camera/src/root.zig:94` is `CameraWith(Backend, y_axis)`).
- **editor bridge contract** — this is v1.5, extending the v1.1–v1.4 line (`editor_api.zig` / `preview.ts`).

## Open questions

1. **Apply-while-paused home.** Extend `editor_api.frame()` to re-apply the authored component when paused, or add a dedicated engine pass gated on `editor_api.isPaused()`? `frame` already runs at the right point (post-tick, pre-render) and already owns the override; folding the component-apply there keeps the precedence ordering in one place. (Leaning: extend `frame`.)
2. **Default-insertion placement — RESOLVED: the assembler calls an engine helper.** The insertion is a **runtime engine helper** (`ensureDefaultCamera(root)`: scan the instantiated tree, insert a default only if none exists) that the **assembler emits a call to** at the root-instantiation site — *not* a comptime codegen decision. The assembler cannot evaluate "an explicit `Camera` anywhere wins" statically (it is a property of the instantiated tree), so the *whether* lives in the engine at runtime and the *where the call goes* lives in the assembler. See §"How this subsumes #564".
3. **Digest `camera` on non-authored default cameras.** Should an engine-inserted default camera (no authored component) still publish its `camera.view` so the studio can gizmo it before the user commits a component? (Leaning: yes — publish for any camera entity; the first gizmo drag materializes an authored component.)
