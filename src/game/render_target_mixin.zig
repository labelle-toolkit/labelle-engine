/// Render-target mixin — offscreen render-to-texture for game code: the
/// transport mirror (render a scene into a texture and draw it somewhere else)
/// and, underneath, the same primitive as headless capture (labelle-bgfx#36).
///
/// Mirrors the `drawMesh` seam (`mesh_mixin.zig`): each method forwards to the
/// renderer's optional render-target op (the gfx `GfxRenderer`/`RetainedEngine`
/// API, labelle-gfx), gated on `@hasDecl` so renderers/backends that don't
/// declare them (raylib/sokol/wgpu/sdl today, and the engine's `StubRender`)
/// compile to a no-op / INVALID. Adding it is therefore non-breaking for every
/// existing game and backend.
///
/// Handles are opaque `u32` ids (like a texture handle), never a backend struct.

/// The id returned by `createRenderTarget` on a renderer without support (or on
/// a create failure); never a valid target. Kept in sync with the backend's
/// `INVALID_RENDER_TARGET` and the gfx forwarder's `0` fallback.
pub const INVALID_RENDER_TARGET: u32 = 0;

/// Returns the render-target mixin for a given Game type.
pub fn Mixin(comptime Game: type) type {
    return struct {
        /// Create an offscreen render target `w`×`h`. Returns an opaque id, or
        /// `INVALID_RENDER_TARGET` (0) when the active renderer has no render-target
        /// support or the backend fails to allocate it. Hand the id back to
        /// `beginRenderTarget` / `drawRenderTarget` / `destroyRenderTarget`.
        pub fn createRenderTarget(self: *Game, w: u16, h: u16) u32 {
            const Renderer = @TypeOf(self.renderer.*);
            if (@hasDecl(Renderer, "createRenderTarget")) {
                return self.renderer.createRenderTarget(w, h);
            }
            return INVALID_RENDER_TARGET;
        }

        /// Point subsequent draws at target `id`: every following draw
        /// (`drawRectangle`, sprites, text, `drawMesh`, …) fills the target's
        /// texture instead of the screen, until `endRenderTarget`. No-op on an
        /// unknown id or a renderer without support.
        pub fn beginRenderTarget(self: *Game, id: u32) void {
            if (id == INVALID_RENDER_TARGET) return;
            const Renderer = @TypeOf(self.renderer.*);
            if (@hasDecl(Renderer, "beginRenderTarget")) self.renderer.beginRenderTarget(id);
        }

        /// Stop drawing into the current render target — subsequent draws return
        /// to the screen (or the enclosing target).
        pub fn endRenderTarget(self: *Game) void {
            const Renderer = @TypeOf(self.renderer.*);
            if (@hasDecl(Renderer, "endRenderTarget")) self.renderer.endRenderTarget();
        }

        /// Draw a finished target `id` into the CURRENT view (call OUTSIDE its own
        /// begin/end) at `x,y` sized `width`×`height`, modulated by the `r,g,b,a`
        /// tint (255,255,255,255 = untinted) — the mirror. No-op on an unknown id
        /// or a renderer without support.
        ///
        /// Coordinates are SCREEN space — top-left origin, Y-down, in pixels — NOT
        /// world/`y_axis` space and not camera-transformed: compositing a render
        /// target is a screen operation (a mirror panel / minimap / HUD element),
        /// like raylib's `DrawTextureRec` of a `RenderTexture2D`.
        pub fn drawRenderTarget(self: *Game, id: u32, x: f32, y: f32, width: f32, height: f32, r: u8, g: u8, b: u8, a: u8) void {
            if (id == INVALID_RENDER_TARGET) return;
            const Renderer = @TypeOf(self.renderer.*);
            if (@hasDecl(Renderer, "drawRenderTarget")) self.renderer.drawRenderTarget(id, x, y, width, height, r, g, b, a);
        }

        /// Free target `id`. No-op on an unknown id or a renderer without support.
        pub fn destroyRenderTarget(self: *Game, id: u32) void {
            if (id == INVALID_RENDER_TARGET) return;
            const Renderer = @TypeOf(self.renderer.*);
            if (@hasDecl(Renderer, "destroyRenderTarget")) self.renderer.destroyRenderTarget(id);
        }
    };
}
