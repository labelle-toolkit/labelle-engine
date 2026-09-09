/// Tween per-frame step function (#669). Paired with `tween.zig` (the
/// data + storage) — the repo's "one type + one tick fn" split, like
/// `sprite_animation` + `sprite_animation_tick`.
///
/// Call once per frame from the engine loop (wire next to
/// `sprite_animation_tick`). Advances every alive tween, applies
/// interpolated values / fires callbacks, kills entity-bound tweens whose
/// entity has despawned, and retires finished tweens to the free list.
///
/// ## Reentrancy
/// A user `apply`/`call` may create or kill tweens (appending to or
/// mutating the system's storage). So the tick:
///   - captures the slot count ONCE up front — tweens created this frame
///     are processed next frame, never mid-iteration;
///   - snapshots a tween's steps into locals and holds NO `*Tween` across
///     any user call (an append can realloc the dense array);
///   - re-fetches the slot after the step loop and re-checks `alive`, so a
///     tween killed inside its own callback is not finalized or looped.

const std = @import("std");
const tween = @import("tween.zig");
const easing = @import("easing.zig");

const TweenSystem = tween.TweenSystem;

/// Liveness backend that reports every entity as alive — for callers that
/// never use `.bindEntity` (and for unit tests without an ECS).
pub const AlwaysAlive = struct {
    pub fn tweenEntityAlive(_: AlwaysAlive, _: u64) bool {
        return true;
    }
};

/// Step all tweens by `dt`. `backend` must expose
/// `pub fn tweenEntityAlive(self, entity: u64) bool` — it is consulted
/// only for tweens with a bound entity. Pass `AlwaysAlive{}` when nothing
/// is bound.
pub fn tick(system: *TweenSystem, dt: f32, backend: anytype) void {
    // Snapshot the slot count: tweens appended during this tick (by a
    // callback calling create) land at index >= n and run next frame.
    const n = system.tweens.items.len;

    var i: usize = 0;
    while (i < n) : (i += 1) {
        // ── advance + liveness (no user calls here; safe to hold t) ──
        {
            const t = &system.tweens.items[i];
            if (!t.alive) continue;
            if (t.bound_entity) |ent| {
                if (!backend.tweenEntityAlive(ent)) {
                    system.freeSlot(@intCast(i));
                    continue;
                }
            }
            t.elapsed += dt;
        }

        // ── snapshot for the step loop (release t before any user call) ──
        var steps: [tween.max_steps]tween.Step = undefined;
        var fired: [tween.max_steps]bool = undefined;
        var step_count: usize = undefined;
        var elapsed: f32 = undefined;
        var expected_gen: u32 = undefined;
        {
            const t = &system.tweens.items[i];
            step_count = t.step_count;
            elapsed = t.elapsed;
            expected_gen = t.generation;
            @memcpy(steps[0..step_count], t.steps[0..step_count]);
            @memcpy(fired[0..step_count], t.fired[0..step_count]);
        }

        // ── process steps over the snapshot; invoke user fns ──
        var s: usize = 0;
        while (s < step_count) : (s += 1) {
            const step = steps[s];
            if (elapsed < step.start_offset) continue; // not started yet
            switch (step.kind) {
                .property, .method => {
                    if (fired[s]) continue; // already landed on `to`
                    const local = elapsed - step.start_offset;
                    if (local >= step.duration) {
                        // Window passed (or instant step): land EXACTLY on
                        // `to`, once — never leave a value at 99.7% because
                        // of frame timing, even if a big dt skipped the whole
                        // window in one tick.
                        if (step.apply) |apply| apply(step.ctx, step.to);
                        fired[s] = true;
                    } else {
                        const v = easing.interpolate(step.from, step.to - step.from, local, step.duration, step.curve, step.placement);
                        if (step.apply) |apply| apply(step.ctx, v);
                    }
                },
                .callback => {
                    if (fired[s]) continue;
                    if (step.call) |call| call(step.ctx);
                    fired[s] = true; // exactly once (even if a large dt skipped its offset)
                },
                .interval => {}, // only contributes to total_duration
            }
        }

        // ── re-fetch; a callback may have killed, reallocated, or even
        // REUSED our slot (kill self + create → same index, new tween).
        // The generation check is load-bearing: without it we would
        // clobber the new occupant's fired bits and finalize it early.
        const t = &system.tweens.items[i];
        if (!t.alive or t.generation != expected_gen) continue;
        @memcpy(t.fired[0..step_count], fired[0..step_count]);

        if (t.total_duration <= 0) {
            // Zero-length tween (only callbacks/instant steps): fired this
            // frame, so it is done. Loops are meaningless with no duration.
            system.freeSlot(@intCast(i));
            continue;
        }

        if (t.elapsed >= t.total_duration) {
            if (t.loops == 0) {
                // Infinite: wrap, carry the remainder, re-arm fired bits.
                t.elapsed -= t.total_duration;
                @memset(t.fired[0..t.step_count], false);
            } else {
                t.loops_done += 1;
                if (t.loops_done >= t.loops) {
                    system.freeSlot(@intCast(i));
                } else {
                    t.elapsed -= t.total_duration;
                    @memset(t.fired[0..t.step_count], false);
                }
            }
        }
    }
}
