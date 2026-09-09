//! Emitter mixin — the per-entity `ParticleSystem` side-table lifecycle
//! (#750). Mirrors `tilemap_mixin.zig`: particle sims can't live inside the
//! ECS component (a `ParticleSystem` owns a heap pool), so they're held in a
//! `Game.particle_systems` `AutoHashMap(Entity, *ParticleSystem)` keyed by
//! entity. This mixin owns create / release / clear / reap / deinit; the
//! per-frame stepping + drawing lives in `particles_tick.zig`.
//!
//! Unlike the tilemap runtime, the particle sim is renderer-agnostic (pure
//! CPU) — only the DRAW folds away on a renderer without `drawMesh` — so the
//! side-table is always present rather than gated on a renderer capability.

const std = @import("std");
const particles = @import("../particles.zig");

const ParticleSystem = particles.ParticleSystem;

pub fn Mixin(comptime Game: type) type {
    const Entity = Game.EntityType;

    return struct {
        /// Opt into the engine-driven particle phase. Set automatically when
        /// a scene loads an `Emitter` (see `component_apply.applyEmitter`), so
        /// scene-authored emitters "just work"; a game with no emitter leaves
        /// it `false` and the tick/draw are byte-identical no-ops.
        pub fn setDriveParticles(self: *Game, on: bool) void {
            self.drive_particles = on;
        }

        /// The live `ParticleSystem` for `entity`, or `null` if none has been
        /// created yet (the tick creates it on first sight).
        pub fn particleSystem(self: *Game, entity: Entity) ?*ParticleSystem {
            return self.particle_systems.get(entity);
        }

        /// Create (or replace) the `ParticleSystem` for `entity` from
        /// `config`, pre-sizing its pool. Idempotent: an existing system for
        /// the entity is released first so a re-acquire (config change,
        /// respawn) can't leak. The heap `*ParticleSystem` has a stable
        /// address, so the map rehashing never moves the pool.
        pub fn acquireParticleSystem(self: *Game, entity: Entity, config: particles.EmitterConfig) !*ParticleSystem {
            releaseParticleSystem(self, entity);
            const sys = try self.allocator.create(ParticleSystem);
            errdefer self.allocator.destroy(sys);
            sys.* = try ParticleSystem.init(self.allocator, config);
            errdefer sys.deinit(self.allocator);
            try self.particle_systems.put(entity, sys);
            return sys;
        }

        /// Free the `ParticleSystem` for `entity` if present. No-op otherwise.
        pub fn releaseParticleSystem(self: *Game, entity: Entity) void {
            if (self.particle_systems.fetchRemove(entity)) |kv| {
                kv.value.deinit(self.allocator);
                self.allocator.destroy(kv.value);
            }
        }

        /// Free every particle system and empty the table (retaining its
        /// capacity). Called from `resetEcsBackend` (scene swap / load): the
        /// ECS is about to be wiped, so every entity key becomes a dangling
        /// handle and must be dropped.
        pub fn clearParticleSystems(self: *Game) void {
            var it = self.particle_systems.valueIterator();
            while (it.next()) |sys_ptr| {
                sys_ptr.*.deinit(self.allocator);
                self.allocator.destroy(sys_ptr.*);
            }
            self.particle_systems.clearRetainingCapacity();
        }

        /// Free any side-table entry whose entity no longer carries the
        /// `Emitter` component in the active ECS — the orphan a generic
        /// `removeComponent` / entity destroy leaves behind. Restart-on-remove
        /// iteration because a `fetchRemove` invalidates the map iterator.
        pub fn reapGhostEmitters(self: *Game) void {
            const Emitter = Game.EmitterComp;
            outer: while (true) {
                var it = self.particle_systems.iterator();
                while (it.next()) |entry| {
                    const entity = entry.key_ptr.*;
                    if (!self.ecs_backend.hasComponent(entity, Emitter)) {
                        releaseParticleSystem(self, entity);
                        continue :outer; // iterator invalidated — restart
                    }
                }
                break;
            }
        }

        /// Free all particle systems and the table itself. Called from
        /// `Game.deinit`.
        pub fn deinitParticleSystems(self: *Game) void {
            clearParticleSystems(self);
            self.particle_systems.deinit();
        }
    };
}
