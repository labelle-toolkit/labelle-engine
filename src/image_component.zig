//! Standalone `Image` component (RFC-UNIFY-SCENES-AND-PREFABS §"Standalone
//! `Image` component", labelle-engine#568).
//!
//! An `Image` entity displays a **standalone PNG** — no atlas, no sub-rect —
//! loaded through the `AssetCatalog` `image` loader (decode-on-worker,
//! upload-on-main, refcounted). It is the entity-side counterpart to that
//! loader: today entities can only show images via atlas sprites
//! (`Sprite.sprite_name` → `TextureManager.findSprite`), and the workaround
//! for a loose PNG is to wrap it as a 1-sprite atlas. `Image` removes that
//! workaround.
//!
//! **Engine built-in, NOT a `ComponentRegistry` component.** Like `Position`,
//! `Tilemap` (`src/tilemap.zig`) and `Camera` (`src/camera.zig`), `Image` is
//! handled by a dedicated built-in channel in the scene loader
//! (`jsonc/component_apply.zig`). The built-in branch is guarded
//! `!Components.has("Image")` so a project-registered `Image` still wins. Do
//! not register it in a game's `ComponentRegistry`.
//!
//! **Renderer-agnostic.** The engine takes no gfx dependency, so `pivot` /
//! `layer` are engine-local (a mirror enum + a layer *name* string) rather
//! than gfx's `Pivot` / comptime `LayerEnum`. The render seam maps them onto
//! the backend. The full-texture draw branch lives renderer-side
//! (labelle-gfx) and is tracked separately — this component + its
//! scene-loader apply + the `AssetCatalog` resolution path are the engine's
//! half of the seam.
//!
//! **Naming caveat.** There is already a `gui_types.Image` in the imgui GUI
//! layer. This ECS `Image` component is distinct: different module, different
//! render path. Reach it as `engine.Image` / `Game.ImageComp`.
//!
//! **V1 scope is deliberately narrow** (issue #568): no animation, no dynamic
//! name swapping, no sub-rect cropping. If any of those is needed, the answer
//! is "use `Sprite` + an atlas". `Image` is for static single-PNG entities
//! and nothing else.

const std = @import("std");

/// Pivot anchor for a standalone `Image`. Engine-local MIRROR of gfx's
/// `Pivot` — the engine takes no gfx dependency, so the render seam maps
/// these names onto the backend's `Pivot` enum. Member names match gfx's
/// exactly so a JSONC `"pivot": "bottom_left"` round-trips through
/// `std.meta.stringToEnum` on both sides.
pub const Pivot = enum {
    center,
    top_left,
    top_center,
    top_right,
    center_left,
    center_right,
    bottom_left,
    bottom_center,
    bottom_right,
    custom,
};

/// The `Image` component — a static single-PNG entity backed by the
/// `AssetCatalog` `image` loader.
///
/// Resolution: `name` is an `AssetCatalog` asset key. The asset is acquired
/// through `game.assets.acquire(name)`; once `game.assets.isReady(name)`, the
/// uploaded GPU texture handle is read from `entry.resource.?.image`
/// (`bridgeImageAssetsToAtlasManager` in `game/scene_mixin.zig` already wires
/// ready `.image` assets into the renderer). Rendering is skipped while the
/// asset is not ready (matches the lazy pop-in model).
pub const Image = struct {
    /// `AssetCatalog` asset key of the standalone PNG. Borrowed from the
    /// scene's nested-entity arena (same lifetime as `Sprite.sprite_name`).
    name: []const u8 = "",

    /// Anchor point — same semantics as `Sprite.pivot`.
    pivot: Pivot = .center,

    /// Layer *name* — same layering model as `Sprite`, but carried as a
    /// string because the engine cannot see the project's comptime layer
    /// enum. The render seam maps it onto the backend layer. Empty = the
    /// renderer's default layer.
    layer: []const u8 = "",

    /// Draw order within the layer — same as `Sprite.z_index` (matches gfx's
    /// `i16` width).
    z_index: i16 = 0,

    /// Visibility toggle — same as `Sprite.visible`.
    visible: bool = true,
};

// Coverage lives in `test/jsonc/image_component_test.zig` — per the engine
// convention, `src/*.zig` test blocks aren't reached by build.zig's
// cross-module test import.

