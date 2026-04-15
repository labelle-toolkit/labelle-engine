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
        self.dirty = true;
    }

    /// Transition using metadata from an AnimationDef.
    pub fn transitionFromMeta(self: *AnimationState, clip: u8, meta: ClipMeta) void {
        self.transition(clip, meta.frame_count, meta.speed, meta.mode);
    }
};
