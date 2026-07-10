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

const std = @import("std");

/// Inline capacity of a camera `tag` (bytes, excluding the sentinel). Mirrors
/// gfx `CameraWith.tag_buf` (`[16:0]u8`, ≤ 15 usable) so a tag authored here
/// round-trips into the gfx camera without truncation.
pub const tag_capacity: usize = 15;

/// Build a sentinel-terminated tag buffer from a comptime string. Used for the
/// `Camera.tag` default; over-long tags are a compile error (they would not
/// fit the gfx camera's inline buffer either).
pub fn makeTag(comptime s: []const u8) [16:0]u8 {
    if (s.len > tag_capacity) @compileError("camera tag must be ≤ 15 bytes: '" ++ s ++ "'");
    var b = [_:0]u8{0} ** 16;
    @memcpy(b[0..s.len], s);
    return b;
}

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

    /// Camera tag (camera-bound layers, labelle-engine#723/#724). Names the
    /// camera slot this entity seeds: `"main"` (the default) drives slot 0 —
    /// the fullscreen game camera — exactly as before; any other tag claims a
    /// secondary slot (1–3) that layers whose `LayerConfig.camera` equals the
    /// tag render through. A world/screen layer with no `.camera` stays on the
    /// main camera.
    ///
    /// Stored INLINE as a sentinel-terminated fixed buffer, NEVER a heap slice:
    /// `applyCameraComponentJson` merges patches through a call-scoped arena
    /// (`camera_mixin.zig`), so a `[]const u8` tag would dangle the moment that
    /// arena is freed. The inline buffer mirrors gfx `CameraWith.tag_buf`.
    tag: [16:0]u8 = makeTag("main"),

    // Reserved for a future declarative follow target (entity id + offset +
    // deadzone). Deferred: shipping games express "follow" in their gameplay
    // script (soft ownership), so v1 does not model it — but the shape is
    // reserved so a later `follow` field is additive, not a rename.
    // follow: ?Follow = null,

    /// The tag as a string view (up to the sentinel). Cheap; no allocation.
    pub fn tagSlice(self: *const Camera) []const u8 {
        return std.mem.sliceTo(&self.tag, 0);
    }

    /// Overwrite the inline tag from a runtime string (JSONC / save-load
    /// channels). Bytes past the 15-byte capacity are dropped so the buffer
    /// always stays sentinel-terminated and interoperable with the gfx camera.
    pub fn setTagSlice(self: *Camera, s: []const u8) void {
        const n = @min(s.len, tag_capacity);
        @memcpy(self.tag[0..n], s[0..n]);
        // Zero the remainder so `tagSlice` (and any raw comparison) is stable.
        @memset(self.tag[n..], 0);
    }
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

/// True when game type `G`'s `CameraManagerType` is the TAGGED multi-camera
/// manager (gfx ≥1.26) — i.e. it declares the full slot/tag seam the
/// camera-bound-layers seeding drives (`resetSecondary` / `setTag` /
/// `setActive` / `getCamera` / `findByTag`). Used to comptime-fold the new
/// multi-slot tagged seeding — and `getCameraByTag` — away on a renderer that
/// has a settable camera but an OLD, non-tagged manager (e.g. a `struct{}`
/// placeholder), which then falls back to the pre-PR single-camera seed rather
/// than failing to compile. The `!= void` guard short-circuits before the
/// `@hasDecl(M, …)` reflection so a camera-less `void` manager never reaches it.
pub fn hasTaggedCameraManager(comptime G: type) bool {
    if (!@hasDecl(G, "CameraManagerType")) return false;
    const M = G.CameraManagerType;
    if (M == void) return false;
    return @hasDecl(M, "resetSecondary") and
        @hasDecl(M, "setTag") and
        @hasDecl(M, "setActive") and
        @hasDecl(M, "getCamera") and
        @hasDecl(M, "findByTag");
}
