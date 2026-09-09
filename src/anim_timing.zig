//! Shared animation timing vocabulary (#667).
//!
//! Two ORTHOGONAL axes describe how a flipbook clip plays. They used to
//! live in separate modules under confusingly-similar names
//! (`animation_def.Mode` vs `sprite_animation.AnimationMode`); this module
//! is the single home so the distinction is teachable and the two
//! surviving tiers (character rigs via `AnimationDef`/`AnimationState`,
//! simple props via `SpriteAnimation`) read the same concepts.
//!
//! NOTE (#667): this ticket only MOVES the enums — no semantic change, no
//! reordering. The old names remain as deprecated aliases so downstream
//! code keeps compiling.

/// How a clip's frame index ADVANCES — which clock drives the timer. A
/// clip has exactly one. (Formerly `animation_def.Mode`.)
pub const AdvanceMode = enum {
    /// `timer += dt * speed`; the frame cycles over wall-clock time.
    time,
    /// The game writes `timer` from a position delta; the frame cycles
    /// over distance travelled (walk/run cadence tied to movement).
    distance,
    /// `frame = 0` always — a single-frame or externally-driven clip.
    static,
};

/// What happens at a clip's BOUNDARY — past the last frame. Orthogonal to
/// `AdvanceMode`. (Formerly `sprite_animation.AnimationMode`.)
pub const BoundaryMode = enum {
    /// Wrap back to frame 0 and keep cycling.
    loop,
    /// Stop on the last frame and hold there.
    once,
    /// Play forward to the last frame, then reverse to 0, flipping at
    /// each endpoint.
    ping_pong,
};
