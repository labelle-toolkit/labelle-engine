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

/// True when the retained engine can forget its post-fx render targets on
/// surface loss (labelle-gfx#364). Older gfx lacks it; those builds keep the
/// pre-#364 behaviour (post-fx lost after a surface cycle).
fn rendererHasPostFxInvalidation(comptime Renderer: type) bool {
    return @hasDecl(Renderer, "GfxEngineType") and
        @hasDecl(Renderer.GfxEngineType, "invalidatePostFxTargets");
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

        /// Surface loss (labelle-gfx#364): every world's post-fx ping-pong
        /// targets died with the GPU context. Forget them, WITHOUT a backend
        /// destroy, so the next post-fx frame re-creates them against the
        /// restored context. The stacks themselves are kept. Without this the
        /// driver keeps the stale ids (the canvas size never changes across a
        /// surface cycle) and post-fx silently stops after resume.
        pub fn invalidateAllPostFxTargets(self: *Game) void {
            const Renderer = @TypeOf(self.renderer.*);
            if (comptime !rendererHasPostFxInvalidation(Renderer)) return;
            self.active_world.renderer.inner.invalidatePostFxTargets();
            var it = self.worlds.valueIterator();
            while (it.next()) |world| world.*.renderer.inner.invalidatePostFxTargets();
        }
    };
}
