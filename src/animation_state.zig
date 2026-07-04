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

    /// Advance the frame timer. Call once per tick.
    pub fn advance(self: *AnimationState, dt: f32) void {
        switch (self.mode) {
            .time => {
                self.timer += dt * self.speed;
                if (self.frame_count > 0) {
                    const fc: f32 = @floatFromInt(self.frame_count);
                    const cycle = @mod(self.timer, fc);
                    self.frame = @min(@as(u8, @intFromFloat(cycle)), self.frame_count - 1);
                }
            },
            .distance => {
                if (self.frame_count > 0) {
                    const fc: f32 = @floatFromInt(self.frame_count);
                    const cycle = @mod(self.timer, fc);
                    self.frame = @min(@as(u8, @intFromFloat(cycle)), self.frame_count - 1);
                }
            },
            .static => {
                self.frame = 0;
            },
        }
    }

    /// Reset timer and frame for a new clip transition.
    pub fn transition(self: *AnimationState, clip: u8, frame_count: u8, speed: f32, mode: Mode) void {
        self.clip = clip;
        self.frame_count = frame_count;
        self.speed = speed;
        self.mode = mode;
        self.frame = 0;
        self.timer = 0;
        self.pending_set = false; // a hard cut clears any queued switch
        self.dirty = true;
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
        switch (switch_mode) {
            .immediate => self.transition(clip, meta.frame_count, meta.speed, meta.mode),
            .sync => {
                const old_clip = self.clip;
                const old_fc = self.frame_count;
                self.clip = clip;
                self.frame_count = meta.frame_count;
                self.speed = meta.speed;
                self.mode = meta.mode;
                if (clip != old_clip) {
                    // Carry the normalized phase into the new timeline.
                    if (old_fc <= 1) {
                        self.timer = 0;
                    } else {
                        const new_fc: f32 = @floatFromInt(meta.frame_count);
                        const of: f32 = @floatFromInt(old_fc);
                        self.timer = self.timer * (new_fc / of);
                    }
                }
                // Same clip → leave timer untouched (skin swap keeps phase).
                self.pending_set = false;
                self.dirty = true;
            },
            .at_end => {
                if (self.mode == .static) {
                    // No cycle exists to wait for → apply immediately.
                    self.transition(clip, meta.frame_count, meta.speed, meta.mode);
                    return;
                }
                self.pending_clip = clip;
                self.pending_frame_count = meta.frame_count;
                self.pending_speed = meta.speed;
                self.pending_mode = meta.mode;
                // Fire at the current clip's NEXT cycle boundary (linear
                // timer units). Recomputed on every request → last-wins.
                const fc: f32 = @floatFromInt(self.frame_count);
                self.pending_at = if (fc > 0)
                    (@floor(self.timer / fc) + 1.0) * fc
                else
                    self.timer;
                self.pending_set = true;
            },
        }
    }

    /// Apply a queued `at_end` switch if the current clip has reached its
    /// cycle boundary. Call once per tick from the animation driver, after
    /// `advance`. Returns true when a pending switch was applied this tick.
    pub fn applyPending(self: *AnimationState) bool {
        if (!self.pending_set) return false;
        if (self.timer < self.pending_at) return false;
        self.transition(self.pending_clip, self.pending_frame_count, self.pending_speed, self.pending_mode);
        // `transition` already cleared `pending_set`.
        return true;
    }
};
