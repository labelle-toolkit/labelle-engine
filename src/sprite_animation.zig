//! SpriteAnimation — declarative per-frame sprite cycling.
//!
//! For simple animations that just walk an array of sprite names at a
//! fixed rate, declared inline in a prefab instead of hand-rolling a
//! tick script per use case (condenser pipe, kitchen smoke, hydroponics
//! growth overlay, etc. — see `RFC-PREFAB-ANIMATION.md` for the full
//! motivation).
//!
//! This module adds the component + pure advance() state machine. The
//! ECS tick system that walks `view(.{SpriteAnimation, Sprite}, .{})`
//! and mutates the Sprite's `sprite_name` / `source_rect` / `texture`
//! lives elsewhere (one per game backend; or as an engine helper once
//! the atlas-lookup dependency is resolved).
//!
//! Complements the existing `AnimationState` + `AnimationDef` system,
//! which is tuned for characters with many clips × many variants ×
//! precomputed sprite-name tables. `SpriteAnimation` is the
//! one-clip-fixed-frames primitive: no variants, no clip transitions,
//! no comptime-generated tables — just an array of frame names and an
//! fps rate. Games use `AnimationDef` for workers and
//! `SpriteAnimation` for everything else.

const std = @import("std");
const save_policy = @import("labelle-core").save_policy;

/// How the frame index advances past `frames.len - 1`.
pub const AnimationMode = enum {
    /// Wrap back to 0 and continue cycling. Most animations.
    loop,
    /// Stop on the last frame and stay there. Set-and-forget transitions
    /// (opening a curtain, a one-shot explosion). Game removes the
    /// component to replay.
    once,
    /// Play forward to the last frame, then reverse back to 0, flipping
    /// at each endpoint. Breathing, idle swaying.
    ping_pong,
};

/// Animation component. Attach to any entity that also carries a
/// sprite-like component whose `sprite_name` the engine tick system
/// will rewrite on frame changes.
///
/// Field lifetimes:
/// - `frames` is **borrowed** — typically a comptime slice of static
///   string literals, or a prefab-owned slice in an arena whose
///   lifetime covers the entity. The component does not copy.
/// - `timer` / `frame` / `forward` are runtime state advanced by the
///   tick system; skipped from save via `Saveable.skip` so save files
///   stay small and post-load the animation starts from frame 0 (one-
///   frame visual continuity loss is invisible at 60 fps; a shipping
///   game cares more about the save being small and deterministic).
///
/// Frame count limit: `frame` is stored as `u8`, so `frames.len` must
/// not exceed 255. Simple overlay cycles rarely need more than a dozen
/// frames; use `AnimationDef` / `AnimationState` for character rigs
/// that push against that ceiling.
pub const SpriteAnimation = struct {
    pub const save = save_policy.Saveable(.saveable, @This(), .{
        .skip = &.{ "timer", "frame", "forward" },
    });

    frames: []const []const u8,
    fps: f32,
    mode: AnimationMode = .loop,

    // Runtime state — excluded from save.
    timer: f32 = 0,
    frame: u8 = 0,
    /// Direction of travel in `.ping_pong`. Unused for `.loop` / `.once`.
    forward: bool = true,

    /// Advance the animation by `dt` seconds. Pure state machine —
    /// does not touch the entity's Sprite. The caller (a tick system
    /// that walks `view(.{SpriteAnimation, Sprite}, .{})`) decides
    /// whether to copy the resolved frame name onto the Sprite.
    ///
    /// Returns `true` if `frame` changed this tick (i.e. the caller
    /// should update the Sprite + markVisualDirty). In steady state
    /// (animation playing on a frame it's already on) returns `false`,
    /// which is the common case for single-frame animations or ticks
    /// that fall within the same frame.
    pub fn advance(self: *SpriteAnimation, dt: f32) bool {
        // Degenerate case: empty frames or zero/negative fps. No
        // advance, no mutation. Protects against malformed data
        // (e.g. a prefab with `"frames": []`) without a compile-time
        // constraint that would complicate the prefab schema.
        if (self.frames.len == 0 or self.fps <= 0) return false;
        // `frame` is u8 — enforce the 255-frame ceiling at the call
        // site so misuse surfaces immediately rather than producing a
        // silent wraparound or a cryptic @intCast panic deep in the
        // switch below.
        std.debug.assert(self.frames.len <= std.math.maxInt(u8) + 1);

        const old_frame = self.frame;
        self.timer += dt;
        const frame_duration = 1.0 / self.fps;
        const steps_f: f32 = self.timer / frame_duration;
        const steps: u32 = @intFromFloat(@floor(steps_f));
        if (steps == 0) return false;
        self.timer -= @as(f32, @floatFromInt(steps)) * frame_duration;

        // Each mode advances by `steps` frames with its own wrap rule.
        const len_u8: u8 = @intCast(self.frames.len);
        switch (self.mode) {
            .loop => {
                const base: u32 = self.frame;
                self.frame = @intCast((base + steps) % self.frames.len);
            },
            .once => {
                const base: u32 = self.frame;
                const target = base + steps;
                self.frame = if (target >= self.frames.len)
                    len_u8 - 1
                else
                    @intCast(target);
            },
            .ping_pong => {
                // Iterate per-step so the `forward` flag preserves the
                // "direction we JUST moved in" convention — flipping
                // strictly on direction reversal (at peak / trough),
                // never on landing exactly at an endpoint. Folding the
                // iteration into closed-form modular arithmetic breaks
                // this convention at frames 0 and (len-1) where the
                // analytical `linear_position <= len-1` check can't
                // distinguish "arriving at 0 via reverse" from
                // "arriving at 0 via forward about to peel off".
                // O(steps) per call is fine — at 60 Hz with
                // reasonable fps, steps is 0–1 per tick.
                if (self.frames.len == 1) {
                    self.frame = 0;
                } else {
                    var remaining: u32 = steps;
                    while (remaining > 0) : (remaining -= 1) {
                        if (self.forward) {
                            if (self.frame + 1 >= len_u8) {
                                self.forward = false;
                                self.frame -= 1;
                            } else {
                                self.frame += 1;
                            }
                        } else {
                            if (self.frame == 0) {
                                self.forward = true;
                                self.frame += 1;
                            } else {
                                self.frame -= 1;
                            }
                        }
                    }
                }
            },
        }
        return self.frame != old_frame;
    }

    /// Current frame's sprite name. Returns `null` for a degenerate
    /// zero-frame animation so the caller can handle the case
    /// explicitly rather than indexing into an empty slice.
    pub fn currentSprite(self: *const SpriteAnimation) ?[]const u8 {
        if (self.frames.len == 0) return null;
        return self.frames[self.frame];
    }

    /// Returns `true` when a `.once` animation has played through to
    /// its last frame and will not advance further. The tick system
    /// (or game code) can use this to remove the component and replay
    /// the clip from the start.
    ///
    /// Always returns `false` for `.loop` and `.ping_pong` (neither
    /// finishes) and for degenerate zero-frame animations.
    pub fn isFinished(self: *const SpriteAnimation) bool {
        if (self.mode != .once or self.frames.len == 0) return false;
        return @as(usize, self.frame) + 1 >= self.frames.len;
    }
};
