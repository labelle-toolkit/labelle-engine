//! Pixel-water ECS tick — the per-frame half of the `PixelWater` pairing
//! (`src/pixel_water.zig` is the type), following the engine's "one type +
//! one tick fn, paired" convention.
//!
//! Two jobs per frame, in this order:
//!
//!  1. REAP + RESOLVE. Drop instances whose component is gone (entity
//!     destroyed — `game.destroyEntity` cascades to children, so one destroy
//!     can orphan several — or the component removed), then create the gfx
//!     instance for any reservoir whose mask has since become resident. That
//!     second half is why a streaming mask needs no retry timer: the tick IS
//!     the retry, and it is idempotent.
//!
//!  2. ADVANCE SIMULATION TIME. `advanceWaterTime(id, dt)` with the dt the
//!     caller passed — which is `loop_mixin`'s TIME-SCALED delta, so a hard
//!     pause (`time_scale == 0`) freezes the water and slow-mo slows it. The
//!     shader's clock therefore comes from the engine's simulation step and
//!     NEVER from a wall clock, which is what makes a water test
//!     deterministic (RFC §"Runtime state and API").
//!
//! Folds to nothing on a renderer without labelle-gfx#359's water seam.

const std = @import("std");
const pixel_water = @import("pixel_water.zig");
const pixel_water_mixin = @import("game/pixel_water_mixin.zig");

const PixelWater = pixel_water.PixelWater;

/// Advance every reservoir by `dt` simulation seconds, after reaping orphans
/// and resolving newly-resident masks. Called from `loop_mixin.tick` when
/// `drive_pixel_water` is set.
///
/// `dt == 0` still runs the reap/resolve half (a paused frame must still be
/// able to bind a mask that just finished uploading) but advances no clock —
/// gfx's `advanceTime` is itself a no-op on a zero delta.
pub fn tick(game: anytype, dt: f32) void {
    const Game = @TypeOf(game.*);
    if (comptime !pixel_water_mixin.rendererSupportsWater(Game.RendererType)) return;

    // Instances whose component vanished (destroy / removeComponent).
    game.reapGhostPixelWater();

    var view = game.ecs_backend.view(.{PixelWater}, .{});
    defer view.deinit();

    while (view.next()) |entity| {
        // Idempotent: returns immediately once an instance exists.
        if (!game.resolvePixelWaterInstance(entity)) continue;
        const id = game.waterInstance(entity) orelse continue;
        game.renderer.advanceWaterTime(id, dt) catch {};
    }
}
