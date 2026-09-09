/// Mesh mixin — render-phase custom textured-mesh drawing.
///
/// This is the immediate-mode seam the future `labelle-spine` plugin
/// (Spine skeletal animation, labelle-gfx#290 Stage 4) submits its
/// per-frame skinned meshes through: during the render phase a plugin
/// iterates its own components and calls `game.drawMesh(...)` once per
/// mesh, forwarding straight to the renderer.
///
/// Mirrors the gizmo forwarding seam (`renderGizmos` → renderer's optional
/// `renderGizmoDraws`): `drawMesh` forwards to the renderer's optional
/// `drawMesh` (the gfx `RetainedEngine` public API, labelle-gfx#291), gated
/// on `@hasDecl` so backends/renderers that don't declare it (raylib/sokol/
/// wgpu/sdl today, and the engine's `StubRender`) compile to a no-op. Adding
/// it is therefore non-breaking for every existing game and backend.
const std = @import("std");

/// Returns the mesh mixin for a given Game type.
pub fn Mixin(comptime Game: type) type {
    return struct {
        /// Submit one textured triangle mesh, immediately, during the render
        /// phase. A no-op unless the active renderer declares `drawMesh`.
        ///
        /// Coordinate + buffer conventions match labelle-core's backend
        /// `drawMesh` contract (the renderer converts Y-up→screen):
        ///   - `texture_id`: renderer texture handle to sample.
        ///   - `positions`: xy pairs in game space (position+scale applied by
        ///     the caller). `len == 2 * numVerts`.
        ///   - `uvs`: uv pairs normalised [0,1] into the texture, parallel to
        ///     `positions`. `len == 2 * numVerts`.
        ///   - `colors`: per-vertex RGBA8 packed one u32 per vertex (a tint
        ///     multiplied with the sampled texel). `len == numVerts`.
        ///   - `indices`: triangle-list into the vertex arrays (every 3 form
        ///     one triangle). `len == 3 * numTris`.
        ///   - `blend`: how the mesh composites over what's already drawn.
        ///
        /// The slices are borrowed for the duration of the call only; the
        /// renderer copies/uploads whatever it needs before returning.
        pub fn drawMesh(
            self: *Game,
            texture_id: u32,
            positions: []const f32,
            uvs: []const f32,
            colors: []const u32,
            indices: []const u16,
            blend: Game.BlendMode,
        ) void {
            const Renderer = @TypeOf(self.renderer.*);
            if (@hasDecl(Renderer, "drawMesh")) {
                self.renderer.drawMesh(texture_id, positions, uvs, colors, indices, blend);
            }
        }
    };
}
