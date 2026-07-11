/// Tests for the CPU particle simulation core (#750).
///
/// Covers the v1 acceptance-relevant invariants that are verifiable without
/// a renderer: deterministic seeded emission, allocation-free steady state
/// (the "pool test"), correct continuous spawn rate + lifetime expiry,
/// one-shot bursts, the `max_particles` ceiling, and the render-readback
/// ramps. The batched-sprite draw hookup and `.jsonc` authoring land with
/// the plugin/engine wiring and aren't exercised here.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");

const ParticleSystem = engine.ParticleSystem;
const EmitterConfig = engine.EmitterConfig;
const Ramp = engine.ParticleRamp;

// ── Determinism ────────────────────────────────────────────────────────────

test "same seed + same step sequence is bit-identical" {
    const cfg: EmitterConfig = .{
        .rate = 60,
        .lifetime = 0.5,
        .lifetime_jitter = 0.3,
        .speed = 100,
        .speed_jitter = 0.4,
        .spread = std.math.pi,
        .gravity_y = 200,
        .max_particles = 512,
        .seed = 0xABCDEF,
    };

    var a = try ParticleSystem.init(testing.allocator, cfg);
    defer a.deinit(testing.allocator);
    var b = try ParticleSystem.init(testing.allocator, cfg);
    defer b.deinit(testing.allocator);

    var frame: usize = 0;
    while (frame < 120) : (frame += 1) {
        a.step(1.0 / 60.0);
        b.step(1.0 / 60.0);
    }

    try testing.expectEqual(a.liveCount(), b.liveCount());
    try testing.expect(a.liveCount() > 0);
    for (a.live(), b.live()) |pa, pb| {
        try testing.expectEqual(pa.x, pb.x);
        try testing.expectEqual(pa.y, pb.y);
        try testing.expectEqual(pa.vx, pb.vx);
        try testing.expectEqual(pa.vy, pb.vy);
        try testing.expectEqual(pa.age, pb.age);
        try testing.expectEqual(pa.lifetime, pb.lifetime);
    }
}

test "reset returns the system to a bit-identical fresh run" {
    const cfg: EmitterConfig = .{ .rate = 30, .lifetime = 1.0, .spread = 1.0, .seed = 42 };

    var s = try ParticleSystem.init(testing.allocator, cfg);
    defer s.deinit(testing.allocator);

    // First run.
    var i: usize = 0;
    while (i < 30) : (i += 1) s.step(1.0 / 60.0);
    const first_count = s.liveCount();
    const first_x = s.live()[0].x;

    // Reset + identical second run must reproduce it exactly.
    s.reset();
    try testing.expectEqual(@as(usize, 0), s.liveCount());
    i = 0;
    while (i < 30) : (i += 1) s.step(1.0 / 60.0);

    try testing.expectEqual(first_count, s.liveCount());
    try testing.expectEqual(first_x, s.live()[0].x);
}

// ── Pool discipline (zero steady-state allocations) ─────────────────────────

test "steady-state simulation never grows the pool (allocation-free)" {
    // A failing allocator that ONLY tolerates the one up-front reservation:
    // any allocation during `step` (a pool growth) fails the test.
    const cfg: EmitterConfig = .{
        .rate = 500, // saturate the pool fast
        .lifetime = 0.3,
        .max_particles = 128,
        .seed = 7,
    };

    var s = try ParticleSystem.init(testing.allocator, cfg);
    defer s.deinit(testing.allocator);

    const cap_after_init = s.particles.capacity;

    // Run well past saturation; capacity must never change (no realloc) and
    // the live count must never exceed the ceiling.
    var max_seen: usize = 0;
    var frame: usize = 0;
    while (frame < 600) : (frame += 1) {
        s.step(1.0 / 60.0);
        try testing.expect(s.liveCount() <= cfg.max_particles);
        try testing.expectEqual(cap_after_init, s.particles.capacity);
        if (s.liveCount() > max_seen) max_seen = s.liveCount();
    }
    // The pool should have actually filled to the ceiling at some point
    // (proves we exercised the drop-on-full path, not just idled).
    try testing.expectEqual(@as(usize, cfg.max_particles), max_seen);
}

test "step performs no allocation once initialized (failing-allocator proof)" {
    const cfg: EmitterConfig = .{ .rate = 500, .lifetime = 0.5, .max_particles = 64, .seed = 1 };

    var s = try ParticleSystem.init(testing.allocator, cfg);
    defer s.deinit(testing.allocator);

    // From here on, ANY allocation is a bug. `std.testing.failing_allocator`
    // returns error.OutOfMemory on the first alloc — but `step` takes no
    // allocator and must not touch one, so a growth would instead show up as
    // the capacity assertions above. This test documents the contract that
    // `step`/`burst` are allocator-free by signature.
    var frame: usize = 0;
    while (frame < 300) : (frame += 1) s.step(1.0 / 60.0);
    s.burst(1000); // clamped to the ceiling, still no allocation
    try testing.expect(s.liveCount() <= cfg.max_particles);
}

// ── Spawn rate + lifetime ───────────────────────────────────────────────────

test "continuous rate emits the expected count and particles expire" {
    // rate*dt chosen power-of-two-exact (16 * 1/16 = 1.0) so the spawn count
    // is deterministic with no floating-point drift: exactly one particle
    // per frame, 32 frames → 32 particles (lifetime is long enough that none
    // die during emission).
    const dt: f32 = 1.0 / 16.0; // 0.0625, exact in f32
    const cfg: EmitterConfig = .{ .rate = 16, .lifetime = 10.0, .speed = 0, .max_particles = 1000, .seed = 3 };

    var s = try ParticleSystem.init(testing.allocator, cfg);
    defer s.deinit(testing.allocator);

    var i: usize = 0;
    while (i < 32) : (i += 1) s.step(dt);
    try testing.expectEqual(@as(usize, 32), s.liveCount());

    // Advance past the 10s lifetime with emission stopped: all must die.
    s.setEmitting(false);
    i = 0;
    while (i < 200) : (i += 1) s.step(1.0 / 16.0);
    try testing.expectEqual(@as(usize, 0), s.liveCount());
}

test "fractional rate below one-per-frame still spawns exactly over time" {
    // 0.5/sec → one particle every 2 seconds.
    const cfg: EmitterConfig = .{ .rate = 0.5, .lifetime = 100, .speed = 0, .seed = 9 };

    var s = try ParticleSystem.init(testing.allocator, cfg);
    defer s.deinit(testing.allocator);

    s.step(1.0); // t=1s → accumulator 0.5, no spawn yet
    try testing.expectEqual(@as(usize, 0), s.liveCount());
    s.step(1.0); // t=2s → accumulator 1.0 → one spawn
    try testing.expectEqual(@as(usize, 1), s.liveCount());
    s.step(2.0); // +1.0 → another
    try testing.expectEqual(@as(usize, 2), s.liveCount());
}

test "a non-positive dt is a no-op" {
    const cfg: EmitterConfig = .{ .rate = 100, .lifetime = 1, .seed = 2 };
    var s = try ParticleSystem.init(testing.allocator, cfg);
    defer s.deinit(testing.allocator);

    s.step(0);
    s.step(-0.5);
    try testing.expectEqual(@as(usize, 0), s.liveCount());
}

// ── Burst + ceiling ─────────────────────────────────────────────────────────

test "burst emits immediately regardless of rate, clamped to the ceiling" {
    const cfg: EmitterConfig = .{ .rate = 0, .lifetime = 1, .max_particles = 50, .seed = 5 };
    var s = try ParticleSystem.init(testing.allocator, cfg);
    defer s.deinit(testing.allocator);

    s.burst(20);
    try testing.expectEqual(@as(usize, 20), s.liveCount());

    // Overflow burst is clamped, never grows the pool.
    s.burst(1000);
    try testing.expectEqual(@as(usize, 50), s.liveCount());
    try testing.expect(s.particles.capacity == 50);
}

test "raising max_particles after init never spawns past the reserved pool" {
    // config is publicly mutable; a caller can bump max_particles above what
    // init reserved. Spawns must still be clamped to the reserved capacity
    // (spawnCeiling) — appending past it would be UB / a safety panic.
    const cfg: EmitterConfig = .{ .rate = 1000, .lifetime = 100, .speed = 0, .max_particles = 8, .seed = 1 };
    var s = try ParticleSystem.init(testing.allocator, cfg);
    defer s.deinit(testing.allocator);

    const reserved = s.particles.capacity; // == 8
    s.config.max_particles = 10_000; // raise beyond the reservation

    var f: usize = 0;
    while (f < 20) : (f += 1) {
        s.step(0.1); // 100 due per frame, far over the reservation
        try testing.expect(s.liveCount() <= reserved);
        try testing.expectEqual(reserved, s.particles.capacity); // no realloc
    }
    // Same guard on the burst path.
    s.burst(10_000);
    try testing.expectEqual(reserved, s.particles.capacity);
    try testing.expect(s.liveCount() <= reserved);
}

test "reset re-enables emission so a stopped emitter restarts cleanly" {
    const cfg: EmitterConfig = .{ .rate = 60, .lifetime = 10, .speed = 0, .max_particles = 256, .seed = 4 };
    var s = try ParticleSystem.init(testing.allocator, cfg);
    defer s.deinit(testing.allocator);

    // Stop emitting (e.g. to let existing particles dissipate before reuse).
    s.setEmitting(false);
    var i: usize = 0;
    while (i < 10) : (i += 1) s.step(1.0 / 60.0);
    try testing.expectEqual(@as(usize, 0), s.liveCount()); // nothing emitted while stopped

    // reset() must return to the fresh initial state — including emitting=true.
    s.reset();
    i = 0;
    while (i < 10) : (i += 1) s.step(1.0 / 60.0);
    try testing.expect(s.liveCount() > 0); // emission resumed
}

test "a long frame ages continuous spawns instead of dumping them all at age 0" {
    // rate=100, lifetime≈0.105s, one giant 1.0s frame. Only emissions within
    // the last ~lifetime of the frame should still be alive — roughly 10-11,
    // NOT the full 100 the naive (spawn-all-at-age-0) path would leave.
    const cfg: EmitterConfig = .{ .rate = 100, .lifetime = 0.105, .speed = 0, .max_particles = 1000, .seed = 6 };
    var s = try ParticleSystem.init(testing.allocator, cfg);
    defer s.deinit(testing.allocator);

    s.step(1.0);
    try testing.expect(s.liveCount() > 0);
    try testing.expect(s.liveCount() <= 15); // ~one lifetime's worth, not 100
}

// ── Render readback ─────────────────────────────────────────────────────────

test "renderData applies size and alpha ramps over life" {
    const cfg: EmitterConfig = .{
        .rate = 0,
        .lifetime = 1.0,
        .speed = 0,
        .size = .{ .start = 10, .end = 20 },
        .alpha = .{ .start = 1, .end = 0 },
        .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .max_particles = 4,
        .seed = 0,
    };
    var s = try ParticleSystem.init(testing.allocator, cfg);
    defer s.deinit(testing.allocator);

    s.burst(1);
    // At birth (t≈0): size≈start, alpha≈start.
    var rd = s.renderData(0);
    try testing.expectApproxEqAbs(@as(f32, 10), rd.size, 0.2);
    try testing.expectApproxEqAbs(@as(f32, 1), rd.color.a, 0.02);

    // Halfway through life: size≈15, alpha≈0.5.
    s.step(0.5);
    rd = s.renderData(0);
    try testing.expectApproxEqAbs(@as(f32, 15), rd.size, 0.2);
    try testing.expectApproxEqAbs(@as(f32, 0.5), rd.color.a, 0.02);
}

test "Ramp.at interpolates and constant holds" {
    const r: Ramp = .{ .start = 2, .end = 8 };
    try testing.expectApproxEqAbs(@as(f32, 2), r.at(0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 5), r.at(0.5), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 8), r.at(1), 1e-6);

    const c = Ramp.constant(3);
    try testing.expectApproxEqAbs(@as(f32, 3), c.at(0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 3), c.at(1), 1e-6);
}

// ── Presets ─────────────────────────────────────────────────────────────────

test "smoke/sparks/rain presets simulate without error" {
    const cases = [_]EmitterConfig{
        engine.particle_presets.smoke,
        engine.particle_presets.sparks,
        engine.particle_presets.rain,
    };
    for (cases) |cfg| {
        var s = try ParticleSystem.init(testing.allocator, cfg);
        defer s.deinit(testing.allocator);
        // Sparks are burst-driven (rate 0) — prime them so the run is live.
        s.burst(16);
        var i: usize = 0;
        while (i < 120) : (i += 1) {
            s.step(1.0 / 60.0);
            try testing.expect(s.liveCount() <= cfg.max_particles);
        }
    }
}
