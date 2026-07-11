//! Emitter — the ECS component that authors a particle emitter (#750).
//!
//! Pairs with `particles.zig` (the pure, backend-free CPU sim) and
//! `particles_tick.zig` (the per-frame ECS glue), following the engine's
//! "one type + one tick fn, paired" convention (see `sprite_animation.zig`).
//! An `Emitter` is authored in a scene / prefab like any other component;
//! the tick lazily spins up a pooled `ParticleSystem` for each emitter
//! entity in a Game side-table (mirroring the Tilemap runtime pattern) and
//! steps it, and the render pass draws the live particles through the
//! `drawMesh` immediate-mode seam.
//!
//! Emitter is a **built-in** component (like `Camera` / `Tilemap`): handled
//! by dedicated channels, not registered in a game's `ComponentRegistry`.
//! A project that DOES register its own `Emitter` takes precedence (the
//! scene-loader branch is gated on `!Components.has("Emitter")`).

const particles = @import("particles.zig");
const save_policy = @import("labelle-core").save_policy;

/// Named emitter preset. Selecting one uses that preset's whole
/// `EmitterConfig` (see `particles.presets`); `.none` uses the component's
/// own `config`. Presets keep scene authoring to a single field
/// (`"Emitter": { "preset": "smoke" }`) for the common effects.
pub const EmitterPreset = enum {
    none,
    smoke,
    sparks,
    rain,
};

/// The emitter component. Holds either a named `preset` or an inline
/// `config`. Transient by design — particles carry only presentation, never
/// game state, so (like `SpriteAnimation`) the component is re-derived from
/// the scene/prefab on load rather than serialized. Its runtime
/// `ParticleSystem` lives in the Game's `particle_systems` side-table, keyed
/// by entity, and is created on first tick.
pub const Emitter = struct {
    // `.transient`: never serialized. A save round-trips the scene/prefab
    // that re-declares the emitter, and the live particle pool is transient
    // presentation state that resets cleanly on respawn.
    pub const save = save_policy.Saveable(.transient, @This(), .{});

    /// Named preset selector. When not `.none`, `resolvedConfig` returns the
    /// preset's config and the inline `config` field is ignored.
    preset: EmitterPreset = .none,

    /// Inline emitter configuration, used when `preset == .none`. Authored
    /// directly in the scene (`"Emitter": { "config": { "rate": 30, ... } }`).
    config: particles.EmitterConfig = .{},

    /// The `EmitterConfig` this emitter should simulate — the preset's config
    /// when a preset is selected, otherwise the inline `config`. The tick
    /// snapshots this once when it first creates the entity's `ParticleSystem`.
    pub fn resolvedConfig(self: Emitter) particles.EmitterConfig {
        return switch (self.preset) {
            .none => self.config,
            .smoke => particles.presets.smoke,
            .sparks => particles.presets.sparks,
            .rain => particles.presets.rain,
        };
    }
};
