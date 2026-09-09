//! Particle ECS tick + render pass (#750) — the glue that makes the pure
//! `particles.zig` sim usable in-engine, paired with the `Emitter` component
//! (`emitter.zig`) per the "one type + one tick fn, paired" convention.
//!
//! `tick(game, dt)` walks every `Emitter` entity, lazily creating a pooled
//! `ParticleSystem` for it in the Game side-table (`acquireParticleSystem`),
//! syncing the emission origin from the entity's `Position`, and stepping the
//! sim; it also reaps side-table entries whose emitter was removed.
//!
//! `render(game)` draws the live particles through the immediate-mode
//! `drawMesh` seam (the only non-ECS-entity draw primitive the engine
//! exposes — there is no `drawQuad`). Each particle is a camera-space quad
//! (2 triangles) built from `ParticleSystem.renderData`; particles of one
//! emitter share a texture, so they batch into `drawMesh` calls of up to
//! `quad_batch` quads. On a renderer without `drawMesh` the whole draw folds
//! to a no-op (`game.drawMesh` is `@hasDecl`-gated), so the sim still runs.
//!
//! v1 limitations (tracked on #750): a solid-colour particle submits
//! `texture_id = 0` and relies on the renderer's white/untextured handling;
//! `sprite_frame` selects a texture id but the atlas binding that maps a
//! frame to a real GPU texture is a plugin/render concern. Particles draw in
//! the primary camera transform (not per-layer-culled like tilemaps) — a
//! per-camera pass is a follow-up.

const std = @import("std");
const particles = @import("particles.zig");

const RenderData = particles.RenderData;
const Color = particles.Color;

/// Pack an engine `Color` (`[0,1]` floats) into the ABGR `u32`
/// (`0xAABBGGRR`) the `drawMesh` vertex-colour slice expects — the byte
/// order gfx's `PosTexColorVertex.abgr` / bgfx `Color0` want. Channels are
/// clamped to `[0,1]` before the `* 255` quantise so an over-bright authored
/// colour (or an alpha ramp overshoot) can't wrap the byte.
pub fn packAbgr(c: Color) u32 {
    const r: u32 = @intFromFloat(@round(std.math.clamp(c.r, 0, 1) * 255));
    const g: u32 = @intFromFloat(@round(std.math.clamp(c.g, 0, 1) * 255));
    const b: u32 = @intFromFloat(@round(std.math.clamp(c.b, 0, 1) * 255));
    const a: u32 = @intFromFloat(@round(std.math.clamp(c.a, 0, 1) * 255));
    return (a << 24) | (b << 16) | (g << 8) | r;
}

/// A single particle's camera-space quad: 4 corner positions (xy pairs,
/// CCW from bottom-left), matching UVs, and the packed vertex colour. The
/// index pattern is constant (`0,1,2, 0,2,3`) so it's emitted by the batcher.
pub const Quad = struct {
    /// x0,y0, x1,y1, x2,y2, x3,y3 — bottom-left, bottom-right, top-right, top-left.
    positions: [8]f32,
    uvs: [8]f32,
    color: u32,
};

/// Build the quad for a render-snapshot: a `size × size` square centred on
/// the particle's world position, full `0..1` UVs, and the ramp-applied
/// colour packed to ABGR.
pub fn particleQuad(rd: RenderData) Quad {
    const h = rd.size * 0.5;
    const x = rd.x;
    const y = rd.y;
    return .{
        .positions = .{
            x - h, y - h, // 0 bottom-left
            x + h, y - h, // 1 bottom-right
            x + h, y + h, // 2 top-right
            x - h, y + h, // 3 top-left
        },
        .uvs = .{ 0, 1, 1, 1, 1, 0, 0, 0 },
        .color = packAbgr(rd.color),
    };
}

// ── Tick ────────────────────────────────────────────────────────────────

/// Advance every emitter's particle sim by `dt`. Lazily creates a pooled
/// `ParticleSystem` per `Emitter` entity (snapshotting its resolved config
/// once), syncs the emission origin to the entity's `Position`, and steps.
/// Reaps orphaned side-table entries first so a removed emitter frees its
/// pool. Called from `loop_mixin.tick` when `drive_particles` is set.
pub fn tick(game: anytype, dt: f32) void {
    const Game = @TypeOf(game.*);
    const Emitter = Game.EmitterComp;

    // Drop pools whose emitter component is gone (removed / entity destroyed).
    game.reapGhostEmitters();

    var view = game.ecs_backend.view(.{Emitter}, .{});
    defer view.deinit();

    while (view.next()) |entity| {
        const emitter = game.ecs_backend.getComponent(entity, Emitter) orelse continue;

        // Lazy create-on-first-sight: snapshot the resolved config once. A
        // create failure (OOM on the one pool reservation) skips the entity
        // this frame; it'll retry next frame.
        const sys = game.particleSystem(entity) orelse
            (game.acquireParticleSystem(entity, emitter.resolvedConfig()) catch continue);

        // Track the entity's world position so a moving emitter trails.
        const pos = game.getPosition(entity);
        sys.setOrigin(pos.x, pos.y);

        sys.step(dt);
    }
}

// ── Render ──────────────────────────────────────────────────────────────

/// Max quads submitted per `drawMesh` call. A stack batch of this many keeps
/// the draw allocation-free while still coalescing an emitter's particles
/// into a handful of draw calls (a few thousand particles → ~tens of calls).
const quad_batch = 256;

/// Draw every emitter's live particles via `drawMesh`. No-op when no emitter
/// has particles. Called from `loop_mixin.render` (inside the post-load gate)
/// when `drive_particles` is set.
pub fn render(game: anytype) void {
    if (game.particle_systems.count() == 0) return;
    var it = game.particle_systems.valueIterator();
    while (it.next()) |sys_ptr| {
        renderSystem(game, sys_ptr.*);
    }
}

fn renderSystem(game: anytype, sys: anytype) void {
    const Game = @TypeOf(game.*);
    const live = sys.live();
    if (live.len == 0) return;

    // All particles of one emitter share a texture (its `sprite_frame`, or 0
    // for a solid-colour quad), so the whole emitter batches together.
    const texture_id: u32 = sys.config.sprite_frame orelse 0;

    // Stack batch — flushed via `drawMesh` when full and once at the end.
    var positions: [quad_batch * 8]f32 = undefined;
    var uvs: [quad_batch * 8]f32 = undefined;
    var colors: [quad_batch * 4]u32 = undefined;
    var indices: [quad_batch * 6]u16 = undefined;
    var n: usize = 0; // quads buffered

    for (0..live.len) |i| {
        const q = particleQuad(sys.renderData(i));
        const vbase = n * 4;
        @memcpy(positions[n * 8 ..][0..8], &q.positions);
        @memcpy(uvs[n * 8 ..][0..8], &q.uvs);
        for (0..4) |c| colors[vbase + c] = q.color;
        const ibase = n * 6;
        const vb: u16 = @intCast(vbase);
        indices[ibase + 0] = vb + 0;
        indices[ibase + 1] = vb + 1;
        indices[ibase + 2] = vb + 2;
        indices[ibase + 3] = vb + 0;
        indices[ibase + 4] = vb + 2;
        indices[ibase + 5] = vb + 3;
        n += 1;

        if (n == quad_batch) {
            game.drawMesh(texture_id, positions[0 .. n * 8], uvs[0 .. n * 8], colors[0 .. n * 4], indices[0 .. n * 6], Game.BlendMode.normal);
            n = 0;
        }
    }
    if (n > 0) {
        game.drawMesh(texture_id, positions[0 .. n * 8], uvs[0 .. n * 8], colors[0 .. n * 4], indices[0 .. n * 6], Game.BlendMode.normal);
    }
}
