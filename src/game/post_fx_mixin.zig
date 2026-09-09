//! Post-fx stack passthrough (labelle-gfx#305 Phase 2 Slice C).
//!
//! Forwards the runtime post-fx stack API to the internal gfx retained
//! engine's `PostFxDriver`. The static `project.labelle` `.post_fx` seed
//! (assembler codegen) and these runtime mutators feed the SAME stack.
//!
//! Gated on `@hasDecl` of the renderer's retained-engine type
//! (`GfxEngineType.setPostFx`) so a renderer without the post-fx API — an
//! older gfx (< v1.28.0), StubRender, or a test mock — compiles to a no-op.

const core = @import("labelle-core");

const PostPass = core.backend_contract.PostPass;

/// True when the renderer wraps a retained engine that exposes the post-fx
/// runtime API (gfx >= v1.28.0). Non-gfx / stub renderers fail the guard.
fn rendererHasPostFx(comptime Renderer: type) bool {
    return @hasDecl(Renderer, "GfxEngineType") and
        @hasDecl(Renderer.GfxEngineType, "setPostFx");
}

pub fn Mixin(comptime Game: type) type {
    return struct {
        /// Replace the whole post-fx stack (e.g. the `project.labelle`
        /// `.post_fx` seed, or a "retro mode" swap). No-op when the active
        /// renderer/backend has no post-fx support.
        pub fn setPostFx(self: *Game, passes: []const PostPass) void {
            const Renderer = @TypeOf(self.renderer.*);
            if (comptime rendererHasPostFx(Renderer)) self.renderer.inner.setPostFx(passes);
        }

        /// Append one full-screen pass to the stack.
        pub fn pushPostPass(self: *Game, pass: PostPass) void {
            const Renderer = @TypeOf(self.renderer.*);
            if (comptime rendererHasPostFx(Renderer)) self.renderer.inner.pushPostPass(pass);
        }

        /// Empty the post-fx stack — back to the straight-to-backbuffer path.
        pub fn clearPostFx(self: *Game) void {
            const Renderer = @TypeOf(self.renderer.*);
            if (comptime rendererHasPostFx(Renderer)) self.renderer.inner.clearPostFx();
        }
    };
}
