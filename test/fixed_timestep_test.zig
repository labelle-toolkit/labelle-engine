/// Tests for the fixed-timestep simulation phase (#751).
///
/// A Bevy-`FixedUpdate`-equivalent accumulator phase: with it enabled, the
/// engine drains whole `fixed_dt` slices out of an accumulator each active
/// `tick`, emitting a `fixed_update` hook per slice, and exposes the
/// sub-step remainder as a render-interpolation `fixed_alpha`. The phase is
/// opt-in and default-inert, so a game that never enables it behaves exactly
/// as before.
///
/// The determinism guarantee (identical fixed-step count for the same total
/// elapsed time regardless of render-fps chunking) is exercised with
/// power-of-two dt slices (0.25 / 0.125 / 0.0625) that are exact in both f32
/// and f64, so the assertions carry no floating-point fuzz.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");

const game_mod = engine.game_mod;

// ── Hook recorder ───────────────────────────────────────────────────────

/// Records every `fixed_update` the engine emits, capturing the payload so
/// tests can assert both the step count and the monotonic `step_index`/`dt`.
const FixedRecorder = struct {
    steps: std.ArrayListUnmanaged(Step) = .empty,
    allocator: std.mem.Allocator,

    const Step = struct { step_index: u64, dt: f32 };

    pub fn fixed_update(self: *FixedRecorder, info: anytype) void {
        self.steps.append(self.allocator, .{ .step_index = info.step_index, .dt = info.dt }) catch unreachable;
    }

    pub fn deinit(self: *FixedRecorder) void {
        self.steps.deinit(self.allocator);
    }
};

const TestGame = game_mod.GameWith(*FixedRecorder);

// ── Defaults / opt-in ─────────────────────────────────────────────────────

test "fixed timestep is disabled by default with sane defaults" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try testing.expect(!game.isFixedTimestepEnabled());
    try testing.expectApproxEqAbs(@as(f64, 1.0 / 60.0), game.fixedTimestep(), 1e-9);
    try testing.expectEqual(@as(u64, 0), game.fixedStepCount());
    try testing.expectEqual(@as(f32, 0), game.fixedAlpha());
}

test "disabled phase never steps or touches alpha (byte-identical behaviour)" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    // Ticking a long time with the phase off must not run a single fixed
    // step, and must leave the interpolation alpha at 0.
    var i: usize = 0;
    while (i < 100) : (i += 1) game.tick(0.1);

    try testing.expectEqual(@as(u64, 0), game.fixedStepCount());
    try testing.expectEqual(@as(f32, 0), game.fixedAlpha());
}

// ── Accumulator + alpha ────────────────────────────────────────────────────

test "accumulator drains whole steps and exposes the remainder as alpha" {
    var rec = FixedRecorder{ .allocator = testing.allocator };
    defer rec.deinit();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    game.setHooks(&rec);
    game.setFixedTimestep(0.25);
    game.setFixedTimestepEnabled(true);

    // Exactly one step, no remainder.
    game.tick(0.25);
    try testing.expectEqual(@as(u64, 1), game.fixedStepCount());
    try testing.expectApproxEqAbs(@as(f32, 0), game.fixedAlpha(), 1e-6);

    // Sub-step: no new step, alpha = 0.1 / 0.25 = 0.4.
    game.tick(0.1);
    try testing.expectEqual(@as(u64, 1), game.fixedStepCount());
    try testing.expectApproxEqAbs(@as(f32, 0.4), game.fixedAlpha(), 1e-6);

    // Crossing the boundary: 0.1 + 0.15 = 0.25 → one more step, alpha back to 0.
    game.tick(0.15);
    try testing.expectEqual(@as(u64, 2), game.fixedStepCount());
    try testing.expectApproxEqAbs(@as(f32, 0), game.fixedAlpha(), 1e-6);

    // The hook fired once per step, with a monotonic step_index and the
    // fixed dt as payload.
    try testing.expectEqual(@as(usize, 2), rec.steps.items.len);
    try testing.expectEqual(@as(u64, 0), rec.steps.items[0].step_index);
    try testing.expectEqual(@as(u64, 1), rec.steps.items[1].step_index);
    try testing.expectApproxEqAbs(@as(f32, 0.25), rec.steps.items[1].dt, 1e-6);
}

test "a single frame can run multiple fixed steps" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    game.setFixedTimestep(0.25);
    game.setFixedTimestepEnabled(true);

    // One big frame of 0.75 → three fixed slices in a row.
    game.tick(0.75);
    try testing.expectEqual(@as(u64, 3), game.fixedStepCount());
    try testing.expectApproxEqAbs(@as(f32, 0), game.fixedAlpha(), 1e-6);
}

// ── Determinism across render-fps caps (issue acceptance) ──────────────────

test "fixed-step count is identical regardless of frame chunking (30/60/144fps)" {
    // Same total simulated time (2.0s) delivered as different per-frame dt
    // slices; the accumulator must produce the same number of fixed steps.
    const Case = struct { chunk: f32, frames: usize };
    const cases = [_]Case{
        .{ .chunk = 0.25, .frames = 8 }, // "low fps"
        .{ .chunk = 0.125, .frames = 16 }, // "mid fps"
        .{ .chunk = 0.0625, .frames = 32 }, // "high fps"
    };

    for (cases) |c| {
        var game = TestGame.init(testing.allocator);
        defer game.deinit();
        game.setFixedTimestep(0.25);
        game.setFixedTimestepEnabled(true);

        var f: usize = 0;
        while (f < c.frames) : (f += 1) game.tick(c.chunk);

        // 2.0s / 0.25 = 8 fixed steps, no remainder, for every cap.
        try testing.expectEqual(@as(u64, 8), game.fixedStepCount());
        try testing.expectApproxEqAbs(@as(f32, 0), game.fixedAlpha(), 1e-6);
    }
}

// ── Pause / time_scale interaction ─────────────────────────────────────────

test "fixed phase freezes while paused and scales under slow-mo" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    game.setFixedTimestep(0.25);
    game.setFixedTimestepEnabled(true);

    // Paused: the active-frame body never runs, so no accumulation.
    game.setPaused(true);
    game.tick(1.0);
    try testing.expectEqual(@as(u64, 0), game.fixedStepCount());

    // Slow-mo at 0.5×: a 0.5s frame contributes only 0.25s of scaled time →
    // exactly one fixed step.
    game.setPaused(false);
    game.setTimeScale(0.5);
    game.tick(0.5);
    try testing.expectEqual(@as(u64, 1), game.fixedStepCount());
}

// ── Spiral-of-death guard ──────────────────────────────────────────────────

test "a huge frame is clamped to max_fixed_steps_per_frame and drops backlog" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    game.setFixedTimestep(0.1);
    game.max_fixed_steps_per_frame = 5;
    game.setFixedTimestepEnabled(true);

    // 2.0s worth of backlog would be 20 steps; the guard caps it at 5 and
    // drops the rest so the sim can't enter a catch-up spiral.
    game.tick(2.0);
    try testing.expectEqual(@as(u64, 5), game.fixedStepCount());

    // The backlog is fully dropped on the clamp (clean resync), so alpha is
    // 0 and the next frame starts fresh rather than immediately re-tripping
    // the cap.
    try testing.expectApproxEqAbs(@as(f32, 0), game.fixedAlpha(), 1e-6);

    // A following normal-sized frame advances exactly one step from the
    // resynced accumulator — proof the clamp left a clean state.
    game.tick(0.1);
    try testing.expectEqual(@as(u64, 6), game.fixedStepCount());
}

// ── setFixedTimestep guards ────────────────────────────────────────────────

test "setFixedTimestep ignores non-positive values" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    game.setFixedTimestep(0.02);
    try testing.expectApproxEqAbs(@as(f64, 0.02), game.fixedTimestep(), 1e-9);

    // A zero / negative step would diverge the drain loop — ignored.
    game.setFixedTimestep(0);
    try testing.expectApproxEqAbs(@as(f64, 0.02), game.fixedTimestep(), 1e-9);
    game.setFixedTimestep(-1.0);
    try testing.expectApproxEqAbs(@as(f64, 0.02), game.fixedTimestep(), 1e-9);
}
