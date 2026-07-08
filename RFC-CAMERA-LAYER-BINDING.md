# RFC: Camera-Bound Layers

**Issue:** labelle-toolkit/labelle-engine#723  
**Status:** Draft  
**Author:** Alexandre  
**Date:** 2026-07-08

## Problem

The camera-prefabs MVP (#714) made cameras first-class entities — you can author a `Camera` component, seed it on load, and manipulate it. But at *render* time there is still exactly one camera that matters: the renderer applies a single active camera to every world-space layer and no camera to screen-space layers.

`LayerConfig.space` (labelle-gfx `src/layer.zig`) conflates two orthogonal axes:

1. **Whose transform applies?** — `.world` → the one active camera; `.screen` / `.screen_fill` → none (pinned).
2. **Fit or fill?** — `.screen_fill` stretches to the framebuffer; `.screen` / `.world` aspect-fit.

Because "which camera" is welded to "world vs screen," a game cannot:

- give a backdrop its own slower-panning camera (**parallax**);
- point a minimap / picture-in-picture layer at a **second camera**;
- decouple a pinned HUD from a world that follows the gameplay camera, except by leaning on the implicit `.screen` behavior.

**Concrete case — the Flying-Platform sky.** The sky (backdrop + cloud bands + sun/moon) lives on `screen` / `screen_fill` layers precisely so it does *not* pan with the world camera. That is correct for a static sky, but it also means there is no way to give the sky *depth* — clouds that drift slightly against the platform as the camera moves — without hand-rolling the offset math in a script. Parallax "wants" to be "this layer follows a camera that tracks the main one at a fraction," and today there is no seam to express that.

## Proposal

Introduce a **per-layer camera binding**. A layer names a camera by **tag**; `Camera` entities carry a tag; the renderer resolves tag → camera once per layer per frame and sets it as the active transform for that layer's draws. No tag = pinned (screen-space, today's behavior).

### `LayerConfig` change (labelle-gfx)

```zig
pub const LayerConfig = struct {
    space: LayerSpace = .world,
    order: i8 = 0,
    visible: bool = true,
    /// Camera this layer is transformed by. `null` = pinned (no camera,
    /// screen-space). Resolved against `Camera` entities' `tag` each frame.
    /// `.world` layers implicitly bind to the reserved "main" tag when this
    /// is left null (see Backward compatibility).
    camera: ?[]const u8 = null,
};
```

`space` keeps its meaning for the fit axis (`screen_fill` still means "stretch, skip aspect-fit"). The camera binding is now the *transform* axis, orthogonal to fit.

### `Camera` tag (labelle-engine)

The built-in `Camera` component gains a tag (default keeps single-camera games working):

```zig
pub const Camera = struct {
    zoom: f32 = 1.0,
    viewport: ?Viewport = null,
    /// Layers whose binding equals this tag are transformed by this camera.
    tag: []const u8 = "main",
};
```

### Resolution & render loop

Each frame the engine builds a small `tag → *Camera` map from the live `Camera` entities and hands it to the render pipeline. The retained renderer's existing per-layer loop gains one line — set the active camera for the layer before its draws, alongside the `setApplyFit` toggle already there for `screen_fill`:

```zig
for (sorted_layers) |layer| {
    const cam = camera_registry.resolve(layer.config().camera); // null → pinned/identity
    if (@hasDecl(BackendImpl, "setCamera")) BackendImpl.setCamera(cam);
    if (@hasDecl(BackendImpl, "setApplyFit"))
        BackendImpl.setApplyFit(layer.config().space != .screen_fill);
    self.renderSpritesOnLayer(layer, candidates);
    self.renderShapesOnLayer(layer, candidates);
    self.renderTextsOnLayer(layer, candidates);
}
```

The backend already threads the active camera through `transformX/transformY` before `toNdcX/Y` (see the bgfx/sokol `state.zig`); this just makes *which* camera is active a per-layer decision instead of a per-frame one.

### Culling

World-layer culling currently computes **one** cull viewport per frame and shares it across world layers. With per-layer cameras, the visible region differs per camera, so the cull viewport must be computed **per bound camera** (cache by tag within the frame so N layers sharing a camera still pay for one query). Pinned layers keep the full-scan path they use today.

## Identity: why tags, not entity references

Layers are **comptime** (declared in `project.labelle` / a `LayerEnum`); cameras are **runtime** entities. A comptime layer cannot hold an entity id, so the binding must be an indirection the layer *can* name at comptime — a **tag** (a comptime string). Whichever `Camera` entity currently carries that tag wins. Consequences:

- **Cutscene / camera swap** = move the tag to a different `Camera` entity; no layer edits, no re-plumbing.
- **Multiple cameras with the same tag** = ambiguous; resolve last-wins with a debug warning (see Open questions).
- Keeps **labelle-gfx entity-agnostic**: gfx sees a resolved `?Camera` per layer, never an ECS id — the engine owns the tag→entity map.

## Backward compatibility

Zero migration for existing games:

- `LayerConfig.camera` defaults to `null`. A `.world` layer with a null binding implicitly resolves to the reserved `"main"` tag.
- `Camera.tag` defaults to `"main"`.
- A game with one camera and world layers therefore behaves identically: the single camera is `"main"`, world layers bind to it, `screen`/`screen_fill` layers stay pinned.

## Use cases (worked)

1. **Parallax sky** — sky layer `camera = "sky_parallax"`; a `Camera` tagged `"sky_parallax"` follows `"main"` at 0.4× pan (a tiny built-in "follow at factor" behavior, or a 3-line script). Clouds now drift against the platform with depth; no per-sprite offset math.
2. **Minimap** — `minimap` layer `camera = "overview"`; a `Camera` tagged `"overview"` with a high zoom-out and `viewport = { top-right rect }`. The world renders twice, once per camera, into two viewports.
3. **Pinned HUD** — `ui` layer `camera = null`. Explicitly pinned regardless of any world camera movement.

## Phasing

- **Phase 1 (gfx only).** `LayerConfig.camera` field + per-layer `setCamera` in `retained_engine` + per-camera cull viewport. Prove **parallax** on one layer by setting an alternate camera directly (no engine registry yet). Small, self-contained, and the parallax payoff is immediate.
- **Phase 2 (engine).** `Camera.tag` + the tag→camera registry + wire resolution into the render pipeline. Prove **multi-camera** (minimap) on Flying-Platform.
- **Phase 3.** Split-screen via `Camera.viewport`; a studio gizmo to assign a layer's camera visually (extends the camera-prefab gizmo work).

## Alternatives considered

1. **Keep one global camera; fake parallax per-sprite.** Rejected — it pushes camera math into game scripts (exactly the hand-rolling this avoids) and does nothing for minimap / PiP / split-screen.
2. **Bind layers to camera *entity ids* directly.** Rejected — layers are comptime, ids are runtime; and a cutscene camera swap would force re-binding every affected layer.
3. **A `parallax_factor` on layers, no camera.** Rejected — solves only parallax, not multi-camera; and "follow another camera at a fraction" is already just a camera, so a second concept is redundant.

## Open questions

- **Duplicate tags.** Multiple live `Camera`s sharing a tag: last-wins + debug warning, first-wins, or hard error? Leaning last-wins (predictable with save/load re-lookup) + a one-shot warning.
- **Registry ownership.** Engine-owned map passed down to gfx per frame (keeps gfx entity-agnostic — preferred), vs a minimal registry inside gfx.
- **Parallax-follow primitive.** Is "follow camera X at factor f" a `Camera` field, a built-in behavior, or left to a game script? Out of scope for Phase 1; revisit once the binding exists.
