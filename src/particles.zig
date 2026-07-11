//! Particles — CPU-simulated 2D particle core (#750, `labelle-particles` v1).
//!
//! The reusable, backend-free heart of the particle system: a pooled,
//! seeded, deterministic simulation that a game (or, per the ticket, the
//! `labelle-particles` plugin) drives each frame and then renders through
//! the existing batched sprite path. This module is intentionally decoupled
//! from `Game`, the ECS, and any renderer — it owns nothing but its own
//! particle pool + RNG, so it can be lifted into the plugin repo verbatim
//! or embedded directly.
//!
//! ## Data-oriented, like `tween.zig`
//! Particles are plain structs in one dense pool owned by a
//! `ParticleSystem`, stepped once per frame — NOT per-entity ECS
//! components. Death is an O(1) swap-remove; birth appends into retained
//! capacity. The pool is pre-sized to `EmitterConfig.max_particles` at
//! `init`, and spawns are capped at that ceiling, so **steady-state
//! simulation performs zero allocations** (the acceptance "pool test").
//!
//! ## Determinism
//! Each system carries its own seeded `Xoshiro256` PRNG. Given the same
//! seed and the same sequence of `step(dt)` calls, two systems produce
//! byte-identical particle state — so replays and tests are stable
//! (acceptance "seeded per-emitter RNG").
//!
//! ## Save/load
//! Particles are transient by design and are NEVER serialized (the same
//! stance `tween.zig` takes): they carry no game state, only presentation,
//! and are re-derived by their emitter on load. Because they are not ECS
//! components they fall outside the save walk automatically — the
//! "transient bucket" the acceptance asks for is structural, not a flag.
//!
//! ## What v1 is / isn't
//! In scope here: the emitter config, the pool, the seeded sim, and a
//! render-readback helper. Out of scope (plugin/engine wiring, tracked on
//! #750): the `Emitter` ECS component + `.jsonc` authoring, the batched
//! sprite draw hookup, the studio inspector/preview, and GPU simulation
//! (explicitly a v2 decision).

const std = @import("std");

/// RGBA colour, components in `[0, 1]`. `a` is multiplied by the alpha
/// curve each frame to produce the particle's rendered opacity.
pub const Color = struct {
    r: f32 = 1,
    g: f32 = 1,
    b: f32 = 1,
    a: f32 = 1,

    pub const white: Color = .{ .r = 1, .g = 1, .b = 1, .a = 1 };
};

/// A linear ramp over a particle's normalized life `t ∈ [0, 1]` — the v1
/// authoring primitive for size / alpha over lifetime. Deliberately not a
/// keyframed curve: a `start → end` lerp covers the common effects (fade
/// out, grow, shrink) and keeps emitter presets one line each. A keyframed
/// curve is a natural v2 extension behind the same `at()` call.
pub const Ramp = struct {
    start: f32,
    end: f32,

    pub fn at(self: Ramp, t: f32) f32 {
        return self.start + (self.end - self.start) * t;
    }

    /// A ramp that holds `v` for the whole life.
    pub fn constant(v: f32) Ramp {
        return .{ .start = v, .end = v };
    }
};

/// Authoring-facing emitter description — POD, so it round-trips through
/// scene/prefab reflection like any other component (the `.jsonc` authoring
/// wiring lands with the plugin). All angles are in radians; the engine's
/// y-down convention means `+y` points down, so a "rising smoke" emitter
/// uses a negative-y velocity via `direction`.
pub const EmitterConfig = struct {
    /// Continuous emission rate, particles per second. Fractional rates are
    /// carried across frames by the spawn accumulator, so `rate = 0.5`
    /// emits one particle every two seconds exactly.
    rate: f32 = 20,

    /// Base particle lifetime in seconds, and the ± fraction of random
    /// jitter applied per particle (`0.2` → each particle lives
    /// `lifetime * [0.8, 1.2]`).
    lifetime: f32 = 1.0,
    lifetime_jitter: f32 = 0,

    /// Initial speed (world units/second), its ± fractional jitter, the
    /// central emission `direction` (radians), and the half-angle `spread`
    /// each particle's direction is randomized within (`spread = pi` emits
    /// in all directions).
    speed: f32 = 60,
    speed_jitter: f32 = 0,
    direction: f32 = 0,
    spread: f32 = 0,

    /// Constant acceleration applied every step (world units/second²) —
    /// gravity, wind, buoyancy. y-down, so downward gravity is `+`.
    gravity_x: f32 = 0,
    gravity_y: f32 = 0,

    /// Size (in world units) and alpha multiplier over normalized life.
    size: Ramp = .{ .start = 4, .end = 4 },
    alpha: Ramp = .{ .start = 1, .end = 0 },

    /// Base tint. The rendered alpha is `color.a * alpha.at(t)`.
    color: Color = Color.white,

    /// Optional sprite frame index into the emitter's atlas; `null` renders
    /// a solid-colour quad. The atlas binding itself is a plugin/render
    /// concern — this is just the authored selector.
    sprite_frame: ?u32 = null,

    /// Hard ceiling on live particles. The pool is pre-sized to this, and
    /// spawns are dropped once it's reached — the bound that makes the sim
    /// allocation-free and its cost predictable.
    max_particles: u32 = 1024,

    /// PRNG seed. Two systems with the same seed + same `step` sequence are
    /// bit-identical (determinism acceptance).
    seed: u64 = 0,
};

/// One live particle. `age`/`lifetime` drive the normalized life `t` the
/// size/alpha ramps read; position + velocity integrate each step.
pub const Particle = struct {
    x: f32,
    y: f32,
    vx: f32,
    vy: f32,
    age: f32,
    lifetime: f32,

    /// Normalized life in `[0, 1]` — 0 at birth, 1 at death.
    pub fn t(self: Particle) f32 {
        if (self.lifetime <= 0) return 1;
        const raw = self.age / self.lifetime;
        return if (raw > 1) 1 else raw;
    }
};

/// The renderer-facing snapshot of a particle at the current step: where to
/// draw it and how big / what colour. Produced by `renderData` so the draw
/// side never re-derives the ramps.
pub const RenderData = struct {
    x: f32,
    y: f32,
    size: f32,
    color: Color,
    sprite_frame: ?u32,
};

/// A single emitter's pooled, seeded particle simulation. Own it wherever
/// the emitter lives (a component side-table, a plugin controller); call
/// `step` once per frame and iterate `live()` to render.
pub const ParticleSystem = struct {
    config: EmitterConfig,
    /// The pool. `items.len` is the live count; capacity is retained across
    /// frames (pre-sized in `init`) so births/deaths never allocate.
    particles: std.ArrayListUnmanaged(Particle) = .empty,
    prng: std.Random.DefaultPrng,
    /// Fractional-spawn carry: `rate * dt` accumulates here and whole
    /// particles are drawn out, so sub-1 rates and variable dt stay exact.
    spawn_accumulator: f32 = 0,
    /// When false, no new particles spawn but existing ones keep simulating
    /// to completion (a "stop emitting, let the smoke dissipate" toggle).
    emitting: bool = true,
    /// Emission origin in world space — move it to make a trailing emitter.
    origin_x: f32 = 0,
    origin_y: f32 = 0,

    /// Create a system for `config`, pre-sizing the pool to
    /// `max_particles` so the steady state never allocates. Returns an
    /// error only if that one up-front reservation fails.
    pub fn init(allocator: std.mem.Allocator, config: EmitterConfig) !ParticleSystem {
        var self: ParticleSystem = .{
            .config = config,
            .prng = std.Random.DefaultPrng.init(config.seed),
        };
        try self.particles.ensureTotalCapacityPrecise(allocator, config.max_particles);
        return self;
    }

    pub fn deinit(self: *ParticleSystem, allocator: std.mem.Allocator) void {
        self.particles.deinit(allocator);
    }

    /// Number of live particles this frame.
    pub fn liveCount(self: *const ParticleSystem) usize {
        return self.particles.items.len;
    }

    /// Live particles, for iteration on the render side. Valid until the
    /// next `step` / `reset`.
    pub fn live(self: *const ParticleSystem) []const Particle {
        return self.particles.items;
    }

    /// Toggle continuous emission. Existing particles are untouched.
    pub fn setEmitting(self: *ParticleSystem, on: bool) void {
        self.emitting = on;
    }

    /// Move the emission origin (world space).
    pub fn setOrigin(self: *ParticleSystem, x: f32, y: f32) void {
        self.origin_x = x;
        self.origin_y = y;
    }

    /// Kill every live particle and reseed to the config seed, returning the
    /// system to its exact initial state (retains pool capacity — no
    /// allocation). Use to restart a deterministic replay. `emitting` is
    /// restored to its `true` default so a system stopped via
    /// `setEmitting(false)` (e.g. to let particles dissipate before reuse)
    /// resumes continuous emission on the next `step` — otherwise an
    /// identical post-reset `step` sequence would produce no particles,
    /// breaking the deterministic-restart contract this method advertises.
    pub fn reset(self: *ParticleSystem) void {
        self.particles.clearRetainingCapacity();
        self.prng = std.Random.DefaultPrng.init(self.config.seed);
        self.spawn_accumulator = 0;
        self.emitting = true;
    }

    /// Effective live-particle ceiling: the smaller of the authored
    /// `config.max_particles` and the pool's RESERVED `capacity`. `config`
    /// is publicly mutable, so a caller can raise `max_particles` after
    /// `init` — but the pool was only reserved for the original ceiling, and
    /// `appendAssumeCapacity` would append past the allocation (UB, or a
    /// safety-build panic) if we honoured the raised value. Clamping to
    /// `capacity` keeps every spawn within the reservation; lowering
    /// `max_particles` is still respected (the smaller wins).
    fn spawnCeiling(self: *const ParticleSystem) usize {
        return @min(@as(usize, self.config.max_particles), self.particles.capacity);
    }

    /// Advance the simulation by `dt` seconds: integrate + age every live
    /// particle (swap-removing any that die), then spawn continuous
    /// particles for the elapsed time. A non-positive `dt` is a no-op.
    /// Performs no allocation — the pool was pre-sized in `init`.
    pub fn step(self: *ParticleSystem, dt: f32) void {
        if (dt <= 0) return;

        // Age + integrate. Iterate by index and swap-remove the dead so the
        // pass stays O(live) with no gaps; don't advance `i` after a
        // swap-remove because the moved-in tail element still needs a visit.
        var i: usize = 0;
        while (i < self.particles.items.len) {
            const p = &self.particles.items[i];
            p.age += dt;
            if (p.age >= p.lifetime) {
                _ = self.particles.swapRemove(i);
                continue;
            }
            // Semi-implicit Euler: velocity first, then position — stable
            // under gravity and matches what a physics step would produce.
            p.vx += self.config.gravity_x * dt;
            p.vy += self.config.gravity_y * dt;
            p.x += p.vx * dt;
            p.y += p.vy * dt;
            i += 1;
        }

        if (!self.emitting or self.config.rate <= 0) return;

        // Continuous emission. Each particle due this frame is emitted at its
        // precise sub-frame time and back-integrated to the frame's end, so a
        // long (hitchy) frame doesn't dump the whole interval's worth of
        // particles at age 0. `acc_start` is the fractional carry from prior
        // frames (always in `[0, 1)`); adding `rate * dt` gives how many
        // particle "credits" are available across `[0, dt]`. The k-th credit
        // (k = 1, 2, …) is reached at frame-time `t_emit = (k - acc_start) /
        // rate`, so that particle has already lived `dt - t_emit` seconds by
        // the end of this step. Emissions older than their lifetime are
        // skipped — that is exactly what caps a short-lived effect at ~one
        // lifetime of live particles instead of one whole frame's worth.
        const acc_start = self.spawn_accumulator;
        const acc_end = acc_start + self.config.rate * dt;
        const ceiling = self.spawnCeiling();
        var k: f32 = 1;
        while (k <= acc_end) : (k += 1) {
            if (self.particles.items.len >= ceiling) {
                // Pool full — discard the backlog so a starved frame can't
                // burst past the ceiling once space frees up.
                self.spawn_accumulator = 0;
                return;
            }
            const t_emit = (k - acc_start) / self.config.rate; // seconds into frame
            const initial_age = dt - t_emit; // age at frame end
            self.spawnOne(if (initial_age > 0) initial_age else 0);
        }
        // Carry the sub-1 remainder to the next frame (acc_start was < 1, so
        // `floor(acc_end)` is the count just emitted).
        self.spawn_accumulator = acc_end - @floor(acc_end);
    }

    /// Emit `n` particles immediately (a one-shot burst — explosion, hit
    /// flash), independent of `rate`/`emitting`. Clamped to remaining pool
    /// space. No allocation.
    pub fn burst(self: *ParticleSystem, n: u32) void {
        const ceiling = self.spawnCeiling();
        var k: u32 = 0;
        while (k < n) : (k += 1) {
            if (self.particles.items.len >= ceiling) return;
            self.spawnOne(0);
        }
    }

    /// Spawn a single particle with jittered lifetime, speed, and direction
    /// drawn from the seeded PRNG, then integrated forward by `initial_age`
    /// seconds (0 for a burst / just-due particle; > 0 for one emitted
    /// earlier within a long frame). A particle whose `initial_age` already
    /// meets its lifetime is skipped — it would be born dead — which is what
    /// keeps a long frame from over-spawning short-lived effects. Assumes
    /// pool space (callers check `spawnCeiling`); `appendAssumeCapacity`
    /// keeps it alloc-free. The RNG draws happen BEFORE the skip so the
    /// sequence stays deterministic regardless of how many are skipped.
    fn spawnOne(self: *ParticleSystem, initial_age: f32) void {
        const r = self.prng.random();

        const life_raw = self.config.lifetime * (1 + jitter(r, self.config.lifetime_jitter));
        const speed = self.config.speed * (1 + jitter(r, self.config.speed_jitter));
        const angle = self.config.direction + jitter(r, 1) * self.config.spread;

        // Guard a degenerate authored lifetime so `Particle.t` never divides
        // by zero and the particle dies on its first step.
        const life = if (life_raw > 0) life_raw else std.math.floatEps(f32);

        // Emitted earlier in the frame than its own lifetime → already dead
        // by frame end; don't occupy a pool slot for it.
        if (initial_age >= life) return;

        var vx = @cos(angle) * speed;
        var vy = @sin(angle) * speed;
        var x = self.origin_x;
        var y = self.origin_y;
        // Advance the sub-frame time already elapsed (semi-implicit Euler,
        // matching `step`'s per-frame integration) so a back-in-time
        // continuous spawn lands where it would have travelled to.
        if (initial_age > 0) {
            vx += self.config.gravity_x * initial_age;
            vy += self.config.gravity_y * initial_age;
            x += vx * initial_age;
            y += vy * initial_age;
        }

        self.particles.appendAssumeCapacity(.{
            .x = x,
            .y = y,
            .vx = vx,
            .vy = vy,
            .age = initial_age,
            .lifetime = life,
        });
    }

    /// Render snapshot for particle `i`, applying the size/alpha ramps at
    /// its current normalized life.
    pub fn renderData(self: *const ParticleSystem, i: usize) RenderData {
        const p = self.particles.items[i];
        const life_t = p.t();
        var c = self.config.color;
        c.a *= self.config.alpha.at(life_t);
        return .{
            .x = p.x,
            .y = p.y,
            .size = self.config.size.at(life_t),
            .color = c,
            .sprite_frame = self.config.sprite_frame,
        };
    }
};

/// Symmetric jitter in `[-amount, +amount]` drawn from `r`. `amount` is a
/// fraction (for speed/lifetime) or a `[-1, 1]` scale (for spread, passed
/// `amount = 1`).
fn jitter(r: std.Random, amount: f32) f32 {
    if (amount == 0) return 0;
    // `r.float` is [0,1); map to [-1,1) then scale.
    return (r.float(f32) * 2 - 1) * amount;
}

/// Ready-to-use emitter presets for the acceptance demo (smoke / sparks /
/// rain). Each is a starting point a game clones and tweaks; the `seed` is
/// fixed so the presets themselves are deterministic out of the box.
pub const presets = struct {
    /// Slow, rising, fading, growing puffs. y-down → negative-y direction
    /// rises; low gravity gives a gentle buoyant drift.
    pub const smoke: EmitterConfig = .{
        .rate = 12,
        .lifetime = 2.0,
        .lifetime_jitter = 0.25,
        .speed = 20,
        .speed_jitter = 0.3,
        .direction = -std.math.pi / 2.0, // up
        .spread = 0.35,
        .gravity_y = -6, // buoyant
        .size = .{ .start = 6, .end = 22 },
        .alpha = .{ .start = 0.5, .end = 0 },
        .color = .{ .r = 0.6, .g = 0.6, .b = 0.6, .a = 1 },
        .max_particles = 256,
        .seed = 0x5_010,
    };

    /// Fast, short-lived, gravity-pulled sparks that shrink and fade — a
    /// burst-friendly preset (drive with `burst(n)` on impact).
    pub const sparks: EmitterConfig = .{
        .rate = 0, // burst-driven
        .lifetime = 0.5,
        .lifetime_jitter = 0.4,
        .speed = 180,
        .speed_jitter = 0.5,
        .direction = -std.math.pi / 2.0,
        .spread = std.math.pi, // all directions
        .gravity_y = 400,
        .size = .{ .start = 3, .end = 0.5 },
        .alpha = .{ .start = 1, .end = 0 },
        .color = .{ .r = 1, .g = 0.85, .b = 0.3, .a = 1 },
        .max_particles = 512,
        .seed = 0x5_9a5,
    };

    /// Dense downward streaks. Wide horizontal spawn is the emitter's job
    /// (move `origin` across the top each frame or use several systems);
    /// the sim just gives fast, straight, long-lived falling particles.
    pub const rain: EmitterConfig = .{
        .rate = 200,
        .lifetime = 1.2,
        .lifetime_jitter = 0.1,
        .speed = 500,
        .speed_jitter = 0.1,
        .direction = std.math.pi / 2.0, // down
        .spread = 0.03,
        .gravity_y = 200,
        .size = .{ .start = 2, .end = 2 },
        .alpha = .{ .start = 0.6, .end = 0.6 },
        .color = .{ .r = 0.6, .g = 0.7, .b = 0.9, .a = 1 },
        .max_particles = 2048,
        .seed = 0x5_141,
    };
};
