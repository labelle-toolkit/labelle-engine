//! Fixed-timestep mixin — an accumulator-driven simulation phase (#751).
//!
//! Bevy's `FixedUpdate` equivalent: a stable-dt phase that runs 0..N times
//! per rendered frame so determinism-sensitive logic (physics, lockstep
//! sim) advances on a fixed clock decoupled from render rate. The existing
//! variable-dt phase (`frame_start` → active-scene update → `frame_end`) is
//! untouched — this is *fully additive*.
//!
//! ## Shape
//!
//! Each active `tick` folds the (time-scaled, pause-aware) frame dt into
//! `Game.fixed_accumulator`, then drains whole `fixed_dt` slices out of it,
//! emitting a `fixed_update` hook (+ the tolerant `engine__fixed_tick`
//! event) per slice. Whatever sub-`fixed_dt` remainder is left becomes the
//! **render-interpolation alpha** (`fixed_alpha = accumulator / fixed_dt`,
//! in `[0, 1)`), so a consumer can lerp visual state between the last two
//! fixed states and get smooth motion without simulating at render rate.
//!
//! ## Determinism
//!
//! For the same total elapsed (scaled) time, the same number of fixed steps
//! run regardless of how the time was chunked across frames — so a physics
//! demo produces identical state at fixed-step N whether the render loop is
//! capped at 30, 60, or 144 fps (issue acceptance). The accumulator is `f64`
//! to keep the summation stable across long sessions.
//!
//! ## Pause / time_scale
//!
//! `advanceFixedTimestep` is called from the ACTIVE-frame body of `tick`
//! (after the pause gate), so a paused game accumulates nothing and the
//! phase freezes. It folds the *scaled* dt, so slow-mo (`time_scale < 1`)
//! runs proportionally fewer fixed steps and a hard pause
//! (`time_scale == 0`) runs none — exactly the GameTime semantics the
//! gameplay clock (`clock_s`) already uses.
//!
//! ## Spiral-of-death guard
//!
//! A single frame can never run more than `Game.max_fixed_steps_per_frame`
//! fixed steps; on hitting the cap the entire remaining backlog is dropped
//! (the sim resyncs to "now" rather than freezing while it replays an
//! unbounded burst of lost time after a hitch / breakpoint), which leaves
//! `fixed_alpha` at 0 for a clean restart.
//!
//! Opt-in: `fixed_timestep_enabled` defaults to `false`, and
//! `advanceFixedTimestep` early-returns when it's off, so a project with no
//! `fixed/` systems is byte-identical to before this landed.

const std = @import("std");

/// Returns the fixed-timestep mixin for a given Game type.
pub fn Mixin(comptime Game: type) type {
    return struct {
        /// Enable / disable the fixed-timestep phase. When off (the
        /// default) `advanceFixedTimestep` is a no-op — no accumulation,
        /// no `fixed_update` hooks, `fixed_alpha` stays 0. Toggling it off
        /// mid-run leaves the accumulator as-is (it simply stops draining)
        /// so re-enabling picks up where it left off.
        pub fn setFixedTimestepEnabled(self: *Game, enabled: bool) void {
            self.fixed_timestep_enabled = enabled;
        }

        /// `true` when the fixed-timestep phase is active.
        pub fn isFixedTimestepEnabled(self: *Game) bool {
            return self.fixed_timestep_enabled;
        }

        /// Set the fixed step length in seconds (project-configurable;
        /// default 1/60). Non-positive AND non-finite (`NaN` / `Infinity`)
        /// values are ignored — a non-positive step would make the drain
        /// loop diverge, and a `NaN` would silently poison `fixed_dt`,
        /// `fixed_accumulator`, and `fixed_alpha` (every `NaN` comparison is
        /// false, so it slips past a bare `<= 0` guard). A bad call leaves
        /// the previous step in place. Does not reset the accumulator or the
        /// step counter.
        pub fn setFixedTimestep(self: *Game, seconds: f64) void {
            if (seconds <= 0 or !std.math.isFinite(seconds)) return;
            self.fixed_dt = seconds;
        }

        /// The fixed step length in seconds.
        pub fn fixedTimestep(self: *Game) f64 {
            return self.fixed_dt;
        }

        /// Render-interpolation factor in `[0, 1)`: the fraction of a
        /// `fixed_dt` slice that has accumulated since the last fixed step.
        /// Use it to lerp visual state between the previous and current
        /// fixed states — `rendered = prev + (curr - prev) * fixedAlpha()`
        /// — for smooth motion at any render rate. Stays 0 while the phase
        /// is disabled.
        pub fn fixedAlpha(self: *Game) f32 {
            return self.fixed_alpha;
        }

        /// Monotonic count of fixed steps run since game start (never reset
        /// across frames). Handy for lockstep sequencing and
        /// state-hash-at-step-N determinism assertions.
        pub fn fixedStepCount(self: *Game) u64 {
            return self.fixed_step_count;
        }

        /// Fold one frame's (already time-scaled) dt into the accumulator
        /// and drain whole `fixed_dt` slices, emitting a `fixed_update`
        /// hook per slice. Called from the active-frame body of `tick`;
        /// safe to call directly in tests. No-op while disabled. See the
        /// module doc for the determinism / pause / spiral-guard contract.
        pub fn advanceFixedTimestep(self: *Game, scaled_dt: f32) void {
            if (!self.fixed_timestep_enabled) return;
            // Defensive: a non-positive OR non-finite step (never set through
            // `setFixedTimestep`, but a game could poke the field directly)
            // would make the drain loop never terminate or poison the
            // accumulator with `NaN`. Treat it as "no phase". The
            // `isFinite` half also covers a directly-set `NaN`/`Inf`, which
            // slips past a bare `<= 0` compare.
            if (self.fixed_dt <= 0 or !std.math.isFinite(self.fixed_dt)) return;
            // Reject a negative / non-finite frame dt (time reversal, clock
            // jitter, a NaN from upstream) before it corrupts the
            // accumulator — a negative fold would push the accumulator below
            // zero and skew every subsequent step boundary. A zero dt is a
            // valid no-progress frame and falls through harmlessly.
            if (!std.math.isFinite(scaled_dt) or scaled_dt < 0) return;

            self.fixed_accumulator += @as(f64, scaled_dt);

            // Boundary tolerance: f32 frame-dt chunkings that should sum to a
            // whole number of steps (e.g. 50×`tick(0.02)` or 100×`tick(0.01)`
            // ≈ 1s at the 1/60 default) land the accumulator a hair below the
            // next `fixed_dt` and would run one FEWER step than a 60 FPS
            // chunking — breaking the advertised cross-FPS deterministic step
            // count at boundary times. Draining when within `drain_eps` of a
            // step edge closes that gap; the epsilon is far too small
            // (1e-4 of a step) to ever manufacture a spurious extra step, and
            // the resulting slightly-negative remainder is clamped below.
            const drain_eps = self.fixed_dt * 1e-4;

            var steps: u32 = 0;
            while (self.fixed_accumulator + drain_eps >= self.fixed_dt) {
                self.fixed_accumulator -= self.fixed_dt;

                self.emitHook(.{ .fixed_update = .{
                    .step_index = self.fixed_step_count,
                    .dt = @floatCast(self.fixed_dt),
                } });
                // Tolerant dual-emit (#578): folds to a no-op unless the
                // project's `GameEvents` carries `engine__fixed_tick`
                // (assembler-built games) — unit-test games with
                // `GameEvents = void` skip it entirely. Emitted SYNCHRONOUSLY
                // (not buffered) so flow-driven fixed systems run in this
                // fixed slice, before the variable update — not a phase late
                // after the end-of-frame buffer drain. See
                // `emitEngineEventSync`.
                self.emitEngineEventSync("engine__fixed_tick", .{
                    .step_index = self.fixed_step_count,
                    .dt = @as(f32, @floatCast(self.fixed_dt)),
                });

                self.fixed_step_count += 1;
                steps += 1;

                if (steps >= self.max_fixed_steps_per_frame) {
                    // Spiral-of-death guard: we've hit the per-frame cap.
                    // Drop the entire remaining backlog so a long frame (a
                    // hitch, a debugger pause) can't trigger an unbounded
                    // catch-up burst — the sim resyncs to "now" rather than
                    // trying to replay lost time. Phase alignment is already
                    // gone once we discard time, so a clean zero keeps
                    // `fixed_alpha` a valid interpolation factor (0) rather
                    // than a near-`fixed_dt` remainder that would immediately
                    // re-trip the cap next frame.
                    self.fixed_accumulator = 0;
                    break;
                }
            }

            // Clamp to `[0, ∞)`: the `drain_eps` boundary drain can leave the
            // remainder a hair below zero, and any residual fp underflow must
            // not surface as a negative `fixed_alpha` (the documented range
            // is `[0, 1)`). `@max` keeps it a valid interpolation factor.
            self.fixed_alpha = @max(0.0, @as(f32, @floatCast(self.fixed_accumulator / self.fixed_dt)));
        }
    };
}
