/// AnimationState — lightweight runtime animation component.
///
/// Stores the current clip, variant, frame, and timing state as integer
/// indices into a comptime AnimationDef table. The engine's resolveAtlasSprites
/// reads this to look up precomputed sprite names — no runtime string
/// formatting or allocation needed.
///
/// Games add this component to entities that need sprite animation.
/// Transitions are driven by calling `transition()` (from hooks or scripts).
/// Frame advancement and sprite resolution are handled by the engine.

const animation_def = @import("animation_def.zig");
pub const Mode = animation_def.Mode;
pub const ClipMeta = animation_def.ClipMeta;

/// How a requested clip switch is applied (#671). All three are hard cuts
/// — no blending (a flipbook has no poses to blend). Mirrors Godot's
/// AnimationNodeStateMachineTransition switch modes.
pub const SwitchMode = enum(u8) {
    /// Cut now: `frame = 0`, `timer = 0` (today's `transition`).
    immediate,
    /// Defer until the current clip completes its current cycle, then cut.
    /// A `.static` clip has no cycle, so it applies immediately.
    at_end,
    /// Cut now but carry the normalized playback position into the new
    /// clip: `new_timer = old_timer * new_frame_count / old_frame_count`.
    /// Switching to the SAME clip (a variant/skin swap) leaves the timer
    /// untouched — the Godot skin-swap idiom, no phase reset.
    sync,
};

pub const AnimationState = struct {
    /// Current clip index (into AnimationDef clip table).
    clip: u8 = 0,

    /// Character variant index (into AnimationDef variant table).
    variant: u8 = 0,

    /// Frame count for the current clip.
    frame_count: u8 = 1,

    /// Animation speed multiplier.
    speed: f32 = 1.0,

    /// How frames are advanced.
    mode: Mode = .static,

    /// Current frame index (0-based). Advanced each tick.
    frame: u8 = 0,

    /// Accumulated time/distance for cycling.
    timer: f32 = 0.0,

    /// Last beat position processed by `advanceStateEvents` (#670). Transient
    /// event-tracking state — never serialized; resets to 0 on transition so
    /// a new clip never fires stale markers from the abandoned one.
    event_pos: f32 = 0.0,

    /// Saturating loop count for `AnimLoopEnd` (#670). Transient; resets on
    /// transition.
    repetition: u16 = 0,

    /// Whether the sprite should be flipped horizontally.
    flip_x: bool = false,

    /// Set on clip transition, cleared after the sprite is resolved.
    dirty: bool = true,

    // ── #671 transition queue (all transient — never serialized) ──
    /// One-slot queue for an `at_end` switch. Valid iff `pending_set`.
    pending_clip: u8 = 0,
    pending_frame_count: u8 = 1,
    pending_speed: f32 = 1.0,
    pending_mode: Mode = .static,
    /// Timer value (linear, in cycle units) at which the pending clip
    /// applies — the current clip's next cycle boundary.
    pending_at: f32 = 0,
    pending_set: bool = false,

    /// Advance the frame timer. Call once per tick. Delegates to the
    /// single shared `advanceAny` implementation (#667).
    pub fn advance(self: *AnimationState, dt: f32) void {
        advanceAny(self, dt);
    }

    /// Reset timer and frame for a new clip transition.
    pub fn transition(self: *AnimationState, clip: u8, frame_count: u8, speed: f32, mode: Mode) void {
        transitionAny(self, clip, frame_count, speed, mode);
    }

    /// Transition using metadata from an AnimationDef.
    pub fn transitionFromMeta(self: *AnimationState, clip: u8, meta: ClipMeta) void {
        self.transition(clip, meta.frame_count, meta.speed, meta.mode);
    }

    /// Request a clip switch with explicit semantics (#671). See
    /// `SwitchMode`. `.immediate`/`.sync` apply now; `.at_end` queues the
    /// switch for the current clip's next cycle boundary (a second
    /// `.at_end` overwrites the slot — last-wins).
    pub fn requestTransition(self: *AnimationState, clip: u8, meta: ClipMeta, switch_mode: SwitchMode) void {
        requestTransitionAny(self, clip, meta, switch_mode);
    }

    /// Apply a queued `at_end` switch if the current clip has reached its
    /// cycle boundary. Call once per tick from the animation driver, after
    /// `advance`. Returns true when a pending switch was applied this tick.
    pub fn applyPending(self: *AnimationState) bool {
        return applyPendingAny(self);
    }
};

/// The single source of the flipbook advance math (#667). Advances any
/// state-shaped struct with `.mode` (`AdvanceMode`) / `.speed` / `.timer`
/// / `.frame` / `.frame_count`. Duck-typed via `anytype` so a game
/// wrapper carrying its own typed `Clip`/`Variant` enum fields delegates
/// here instead of copying the math — the extra fields are untouched,
/// which sidesteps the enum-vs-u8 mismatch that motivated the copy.
pub fn advanceAny(state: anytype, dt: f32) void {
    switch (state.mode) {
        .static => {
            state.frame = 0;
            return;
        },
        // .time drives the timer from dt; .distance has the game write
        // the timer externally. The frame derivation is shared below.
        .time => state.timer += dt * state.speed,
        .distance => {},
    }
    if (state.frame_count > 0) {
        const fc: f32 = @floatFromInt(state.frame_count);
        const cycle = @mod(state.timer, fc);
        state.frame = @min(@as(u8, @intFromFloat(cycle)), state.frame_count - 1);
    }
}


/// Duck-typed hard-cut transition (#686): sets the core clip fields on
/// any state-shaped struct — the wrapper's `clip` may be a typed enum
/// (the engine component's is `u8`; both type-check at instantiation).
/// The #670 event fields and the #671 queue are reset only when the
/// struct HAS them, so minimal wrappers work unchanged.
pub fn transitionAny(state: anytype, clip: anytype, frame_count: u8, speed: f32, mode: Mode) void {
    const S = @TypeOf(state.*);
    state.clip = clip;
    state.frame_count = frame_count;
    state.speed = speed;
    state.mode = mode;
    state.frame = 0;
    state.timer = 0;
    // A hard cut clears any queued switch.
    if (@hasField(S, "pending_set")) state.pending_set = false;
    // Reset #670 event tracking — no marker catch-up across a cut clip.
    if (@hasField(S, "event_pos")) state.event_pos = 0;
    if (@hasField(S, "repetition")) state.repetition = 0;
    state.dirty = true;
}

/// Duck-typed `requestTransition` (#671 semantics, #686 wrapper drop-in).
/// `.immediate`/`.sync` need only the core fields; `.at_end` additionally
/// requires the queue fields (`pending_clip` of the same type as `clip`,
/// `pending_frame_count`, `pending_speed`, `pending_mode`, `pending_at`,
/// `pending_set`) — using it without them is a compile error, which is
/// the correct failure mode.
pub fn requestTransitionAny(state: anytype, clip: anytype, meta: ClipMeta, switch_mode: SwitchMode) void {
    const S = @TypeOf(state.*);
    switch (switch_mode) {
        .immediate => transitionAny(state, clip, meta.frame_count, meta.speed, meta.mode),
        .sync => {
            const old_clip = state.clip;
            const old_fc = state.frame_count;
            state.clip = clip;
            state.frame_count = meta.frame_count;
            state.speed = meta.speed;
            state.mode = meta.mode;
            if (clip != old_clip) {
                // Carry the normalized phase into the new timeline.
                if (old_fc <= 1) {
                    state.timer = 0;
                } else {
                    const new_fc: f32 = @floatFromInt(meta.frame_count);
                    const of: f32 = @floatFromInt(old_fc);
                    state.timer = state.timer * (new_fc / of);
                }
            }
            // Same clip → leave timer untouched (skin swap keeps phase).
            if (@hasField(S, "pending_set")) state.pending_set = false;
            state.dirty = true;
        },
        .at_end => {
            if (state.mode == .static) {
                // No cycle exists to wait for → apply immediately.
                transitionAny(state, clip, meta.frame_count, meta.speed, meta.mode);
                return;
            }
            state.pending_clip = clip;
            state.pending_frame_count = meta.frame_count;
            state.pending_speed = meta.speed;
            state.pending_mode = meta.mode;
            // Fire at the current clip's NEXT cycle boundary (linear
            // timer units). Recomputed on every request → last-wins.
            const fc: f32 = @floatFromInt(state.frame_count);
            state.pending_at = if (fc > 0)
                (@floor(state.timer / fc) + 1.0) * fc
            else
                state.timer;
            state.pending_set = true;
        },
    }
}

/// Duck-typed `applyPending` (#686): apply a queued `at_end` switch once
/// the linear timer crosses the recorded boundary. Call once per tick
/// after the advance. Returns true when the switch applied.
pub fn applyPendingAny(state: anytype) bool {
    if (!state.pending_set) return false;
    if (state.timer < state.pending_at) return false;
    transitionAny(state, state.pending_clip, state.pending_frame_count, state.pending_speed, state.pending_mode);
    // `transitionAny` already cleared `pending_set`.
    return true;
}
