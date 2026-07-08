//! Camera component (camera-prefabs MVP, labelle-engine#714 / RFC-CAMERA-PREFABS).
//!
//! A `Camera` entity makes the game camera an AUTHORED / seed entity the
//! studio can select, inspect, gizmo, and save — WITHOUT taking the camera
//! away from games that drive it from a gameplay script. The component is a
//! **seed, not a leash**: it seeds `getCamera()` once on scene load and is
//! re-applied every frame WHILE PAUSED (when no gameplay script is ticking to
//! fight it); on resume the script drives again and the component lies
//! dormant. See the RFC "soft ownership" section.
//!
//! **Engine built-in, NOT a `ComponentRegistry` component.** Like `Position`
//! and `Tilemap` (`src/tilemap.zig`), `Camera` is handled by dedicated
//! built-in channels — the scene loader (`jsonc/component_apply.zig`), the
//! seed/apply sync (`game/camera_mixin.zig`), the studio digest, and the
//! editor bridge (`editor_api.zig`). Do not register it in a game's
//! `ComponentRegistry`.
//!
//! **Renderer-agnostic.** The engine takes no gfx dependency, so `Viewport`
//! below is an engine-local rect — it deliberately does NOT reference gfx's
//! `ScreenViewport`. It is INERT in the single-camera MVP (the runtime always
//! renders fullscreen and ignores a non-null value); it is carried now so the
//! deferred multi-camera work (split-screen / minimap / PiP) is purely
//! additive rather than a breaking component change.

/// Screen-space viewport placement for a camera (split-screen / minimap /
/// PiP). Engine-local and inert in the MVP — see the module header. All fields
/// default so a partial authored/patched `viewport` round-trips cleanly.
pub const Viewport = struct {
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
};

/// The `Camera` component — the AUTHORED / seed camera state. Reachable on a
/// configured game as `Game.CameraComp`. The camera's world CENTER is its
/// `Position` (xy); this component carries only what `Position` doesn't.
pub const Camera = struct {
    /// World→screen zoom. Seeds `getCamera().setZoom` on load; the gfx camera
    /// clamps it to its own `min_zoom`/`max_zoom`.
    zoom: f32 = 1.0,

    /// Optional screen-space viewport placement. `null` = fullscreen. Inert in
    /// the single-camera MVP (always fullscreen); carried for forward-compat
    /// with the deferred multi-camera authoring work.
    viewport: ?Viewport = null,

    // Reserved for a future declarative follow target (entity id + offset +
    // deadzone). Deferred: shipping games express "follow" in their gameplay
    // script (soft ownership), so v1 does not model it — but the shape is
    // reserved so a later `follow` field is additive, not a rename.
    // follow: ?Follow = null,
};

/// True when game type `G` exposes a SETTABLE camera — i.e. its renderer has a
/// real `CameraType` (not the `void` a camera-less/stub renderer publishes)
/// with `setPosition`/`setZoom`. Used to comptime-fold the whole seed /
/// apply-while-paused path away on camera-less renderers. Mirrors
/// `editor_api.gameHasCamera`; the `!= void` guard short-circuits before the
/// `@hasDecl(G.CameraType, …)` reflection so `void` never reaches it.
pub fn hasSettableCamera(comptime G: type) bool {
    if (!@hasDecl(G, "CameraType")) return false;
    if (G.CameraType == void) return false;
    return @hasDecl(G.CameraType, "setPosition") and @hasDecl(G.CameraType, "setZoom");
}
