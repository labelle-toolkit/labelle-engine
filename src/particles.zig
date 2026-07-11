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
    /// allocation). Use to restart a deterministic replay.
    pub fn reset(self: *ParticleSystem) void {
        self.particles.clearRetainingCapacity();
        self.prng = std.Random.DefaultPrng.init(self.config.seed);
        self.spawn_accumulator = 0;
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

        // Draw whole particles out of the fractional-spawn accumulator, so
        // any rate (incl. < 1/frame) and any dt spawn the exact expected
        // count over time. Capped at `max_particles` — surplus is dropped,
        // never grows the pool.
        self.spawn_accumulator += self.config.rate * dt;
        while (self.spawn_accumulator >= 1) {
            self.spawn_accumulator -= 1;
            if (self.particles.items.len >= self.config.max_particles) {
                // Pool full — discard the backlog so a starved frame can't
                // burst past the ceiling once space frees up.
                self.spawn_accumulator = 0;
                break;
            }
            self.spawnOne();
        }
    }

    /// Emit `n` particles immediately (a one-shot burst — explosion, hit
    /// flash), independent of `rate`/`emitting`. Clamped to remaining pool
    /// space. No allocation.
    pub fn burst(self: *ParticleSystem, n: u32) void {
        var k: u32 = 0;
        while (k < n) : (k += 1) {
            if (self.particles.items.len >= self.config.max_particles) return;
            self.spawnOne();
        }
    }

    /// Spawn a single particle at the origin with jittered lifetime, speed,
    /// and direction drawn from the seeded PRNG. Assumes pool space (callers
    /// check `max_particles`); `appendAssumeCapacity` keeps it alloc-free.
    fn spawnOne(self: *ParticleSystem) void {
        const r = self.prng.random();

        const life = self.config.lifetime * (1 + jitter(r, self.config.lifetime_jitter));
        const speed = self.config.speed * (1 + jitter(r, self.config.speed_jitter));
        const angle = self.config.direction + jitter(r, 1) * self.config.spread;

        self.particles.appendAssumeCapacity(.{
            .x = self.origin_x,
            .y = self.origin_y,
            .vx = @cos(angle) * speed,
            .vy = @sin(angle) * speed,
            .age = 0,
            // Guard a degenerate authored lifetime so `Particle.t` never
            // divides by zero and the particle dies on its first step.
            .lifetime = if (life > 0) life else std.math.floatEps(f32),
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
