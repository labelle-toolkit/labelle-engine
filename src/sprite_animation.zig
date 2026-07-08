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
const anim_timing = @import("anim_timing.zig");
const anim_events = @import("animation_events.zig");

/// Deprecated alias (#667): the boundary-behavior axis now lives in
/// `anim_timing.BoundaryMode` (`engine.BoundaryMode`). Kept so prefab
/// data and downstream code keep compiling. `loop`/`once`/`ping_pong`.
pub const AnimationMode = anim_timing.BoundaryMode;

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
    // `.transient` because:
    //   * `frames: []const []const u8` isn't serde-writable — the
    //     serializer doesn't support slice-of-slice — so `.saveable`
    //     would fail at comptime if this component were registered.
    //   * The whole point of this component under the prefab-
    //     foundations RFC is that it comes back via Phase 1 re-spawn:
    //     the prefab jsonc redeclares it from scratch on load, so
    //     there's nothing to round-trip through the save file.
    // Runtime state (`timer` / `frame` / `forward`) resets to zero on
    // re-spawn; one-frame visual continuity loss is invisible at 60
    // Hz, and a shipping game cares more about deterministic save
    // shapes than which frame a pipe animation happened to be on.
    pub const save = save_policy.Saveable(.transient, @This(), .{});

    frames: []const []const u8,
    fps: f32,
    mode: AnimationMode = .loop,

    /// Per-animation playback-speed multiplier (#625), applied ON TOP of
    /// the global `time_scale` by the tick (`advance` receives an
    /// already-speed-scaled `dt`). `1.0` reproduces today's behavior;
    /// `2.0` plays twice as fast; `0` pauses just this animation.
    /// NEGATIVE values are treated as paused — the tick clamps the
    /// effective rate to `>= 0`, so a negative `speed` never runs the
    /// clip in reverse (reverse playback is a deferred #625 item).
    ///
    /// Because the multiply lives in the tick, the component's internal
    /// clock (`timer`/`frame`) stays in clip-time, so `progress()` /
    /// `elapsed()` are speed-INDEPENDENT fractions; only the wall-clock
    /// `duration()` folds `speed` in.
    speed: f32 = 1.0,

    /// Frame indices (0-based) that fire an `engine__anim_frame` event
    /// the tick the animation LANDS on them — footstep / hit / spawn
    /// cue frames (#625). Borrowed slice; empty (the default) means no
    /// per-frame events and reproduces today's behavior.
    ///
    /// `u16` (not `u8`) ON PURPOSE: the JSONC scene-bridge deserializer
    /// special-cases every `[]const u8` field as a STRING (for the intern
    /// pool), so a `[]const u8` here couldn't be authored as a number
    /// array — `"event_frames": [2, 5]` would be parsed as a string. A
    /// `[]const u16` falls through to the generic slice→number-array
    /// branch, so scenes / prefabs can author it. Indices `>= frames.len`
    /// (or above the `u8` frame ceiling) simply never match — harmless.
    ///
    /// v1 detects "landed on", not "crossed": a `dt` spike that steps
    /// PAST a marked frame without landing on it misses it (documented
    /// follow-up — the `AnimationDef` path already does crossing-accurate
    /// markers via beat iteration).
    event_frames: []const u16 = &.{},

    // Runtime state — excluded from save.
    timer: f32 = 0,
    frame: u8 = 0,
    /// Direction of travel in `.ping_pong`. Unused for `.loop` / `.once`.
    forward: bool = true,

    /// #670 lifecycle-event tracking. Transient (the whole component is
    /// `.transient`, so these reset on respawn — never serialized).
    /// `finished_emitted` makes `.once` fire `AnimClipEnd` exactly once;
    /// `repetition` is the saturating `.loop`-wrap / `.ping_pong`-reversal
    /// count carried on `AnimLoopEnd`.
    finished_emitted: bool = false,
    repetition: u16 = 0,

    /// Comptime selector of which event KINDS `advanceEventsMasked` queues
    /// into the `PendingBuf` (#625). The tick builds this from the
    /// project's declared `engine__anim_*` variants so the fixed-capacity
    /// buffer only ever holds events the game will consume — a project
    /// listening to only `anim_frame` never has its buffer crowded out by
    /// `loop_end` events from a multi-wrap tick. Defaults to all-on (what
    /// the back-compat `advanceEvents` requests).
    pub const EventMask = struct {
        frame: bool = true,
        clip_end: bool = true,
        loop_end: bool = true,
    };

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
        return self.advanceImpl(dt, null, .{});
    }

    /// Like `advance`, but appends ALL event kinds to `out`: `AnimClipEnd`
    /// once when a `.once` clip finishes, `AnimLoopEnd` on each `.loop`
    /// wrap and each `.ping_pong` endpoint reversal, and a per-frame marker
    /// when landing on an `event_frames` index. The driver adds the entity
    /// and forwards `out` to `game.emit`. Kept for callers that want every
    /// kind (e.g. #670 tests); the tick uses `advanceEventsMasked`.
    pub fn advanceEvents(self: *SpriteAnimation, dt: f32, out: *anim_events.PendingBuf) bool {
        return self.advanceImpl(dt, out, .{});
    }

    /// Like `advanceEvents`, but only queues the event kinds selected by
    /// the comptime `mask` (#625) — the fixed `PendingBuf` then holds only
    /// events the project actually listens to. The `repetition` counter
    /// still advances arithmetically across every wrap even for kinds that
    /// aren't queued, so counts stay accurate if the game later reads them.
    pub fn advanceEventsMasked(
        self: *SpriteAnimation,
        dt: f32,
        out: *anim_events.PendingBuf,
        comptime mask: EventMask,
    ) bool {
        return self.advanceImpl(dt, out, mask);
    }

    fn advanceImpl(
        self: *SpriteAnimation,
        dt: f32,
        out: ?*anim_events.PendingBuf,
        comptime mask: EventMask,
    ) bool {
        // Degenerate case: empty frames or zero/negative fps. No
        // advance, no mutation. Protects against malformed data
        // (e.g. a prefab with `"frames": []`) without a compile-time
        // constraint that would complicate the prefab schema.
        if (self.frames.len == 0 or self.fps <= 0) return false;
        // `frame` is u8 — enforce the true 255-frame ceiling here so
        // misuse surfaces immediately rather than producing a silent
        // wraparound or a cryptic @intCast panic when `frames.len` is
        // converted to `u8` below.
        std.debug.assert(self.frames.len <= std.math.maxInt(u8));

        const old_frame = self.frame;
        self.timer += dt;
        // Clamp to zero before the signed → unsigned cast below.
        // `timer` can go sub-zero two ways: a negative `dt` (paused
        // game rewinding its scaled clock, a test driving the tick
        // backwards), or floating-point residual from the previous
        // `timer -= steps * frame_duration` landing marginally under
        // the true remainder. Either leaves `steps_f` negative,
        // which turns `@intFromFloat(@floor(...))` into a u32 cast
        // of a negative value — a runtime trap. Treating the
        // clamped case as "no frame advance this tick" matches the
        // steady-state `steps == 0` branch below.
        if (self.timer < 0) self.timer = 0;
        const frame_duration = 1.0 / self.fps;
        const steps_f: f32 = self.timer / frame_duration;
        const steps: u32 = @intFromFloat(@floor(steps_f));
        if (steps == 0) return false;
        self.timer -= @as(f32, @floatFromInt(steps)) * frame_duration;

        // Each mode advances by `steps` frames with its own wrap rule.
        const len_u8: u8 = @intCast(self.frames.len);
        switch (self.mode) {
            .loop => {
                const total: usize = @as(usize, self.frame) + steps;
                self.frame = @intCast(total % self.frames.len);
                if (out) |o| {
                    const wraps: usize = total / self.frames.len;
                    if (wraps > 0) {
                        const start_rep = self.repetition;
                        // Advance the running count arithmetically — O(1),
                        // accurate even on a huge multi-wrap `dt` spike (tab
                        // resume, debugger pause) that a per-wrap loop would
                        // turn into an unbounded traversal.
                        self.repetition = anim_events.satAddU16Count(start_rep, wraps);
                        if (comptime mask.loop_end) {
                            // Emit at most a buffer's worth of AnimLoopEnd —
                            // the overflow tail is dropped (same observable
                            // result as the old append-until-full loop, but
                            // now bounded by `max_pending`, not `wraps`).
                            // Each emitted event carries its true running
                            // repetition.
                            const room: usize = anim_events.max_pending - o.len;
                            const emit_n: usize = @min(wraps, room);
                            var k: usize = 1;
                            while (k <= emit_n) : (k += 1) {
                                _ = o.append(.{
                                    .kind = .loop_end,
                                    .repetition = anim_events.satAddU16Count(start_rep, k),
                                });
                            }
                        }
                    }
                }
            },
            .once => {
                const target: usize = @as(usize, self.frame) + steps;
                self.frame = if (target >= self.frames.len)
                    len_u8 - 1
                else
                    @intCast(target);
                if (out) |o| {
                    // Fire AnimClipEnd exactly once, the tick it lands on
                    // the final frame.
                    if (comptime mask.clip_end) {
                        if (self.frame + 1 >= len_u8 and !self.finished_emitted) {
                            self.finished_emitted = true;
                            _ = o.append(.{ .kind = .clip_end });
                        }
                    }
                }
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
                                self.emitReversal(out, mask.loop_end); // #670: endpoint reversal
                            } else {
                                self.frame += 1;
                            }
                        } else {
                            if (self.frame == 0) {
                                self.forward = true;
                                self.frame += 1;
                                self.emitReversal(out, mask.loop_end);
                            } else {
                                self.frame -= 1;
                            }
                        }
                    }
                }
            },
        }

        // #625 per-frame events: fire when the tick LANDED the animation
        // on a marked frame. Runs after the mode switch so it's uniform
        // across loop/once/ping_pong. Only emitted when the frame changed
        // (steady-state ticks never re-fire) and only when an event sink
        // is present (plain `advance` skips this entirely).
        if (comptime mask.frame) {
            if (out) |o| {
                if (self.frame != old_frame and self.frameIsMarked(self.frame)) {
                    _ = o.append(.{ .kind = .marker, .frame = self.frame });
                }
            }
        }

        return self.frame != old_frame;
    }

    /// True when the current frame `f` is listed in `event_frames`. Linear
    /// scan — the list is a handful of cue frames in practice. `f` is the
    /// `u8` frame index widened to compare against the `u16` cue values.
    fn frameIsMarked(self: *const SpriteAnimation, f: u8) bool {
        for (self.event_frames) |m| {
            if (m == @as(u16, f)) return true;
        }
        return false;
    }

    /// Record a `.ping_pong` endpoint reversal: always bump the running
    /// `repetition`, and append an `AnimLoopEnd` only when `emit_loop`
    /// (the project listens for loop events). Bumping regardless keeps the
    /// count accurate even when loop events aren't queued.
    fn emitReversal(self: *SpriteAnimation, out: ?*anim_events.PendingBuf, comptime emit_loop: bool) void {
        if (out) |o| {
            self.repetition = anim_events.satAddU16(self.repetition, 1);
            if (comptime emit_loop) {
                _ = o.append(.{ .kind = .loop_end, .repetition = self.repetition });
            }
        }
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

    // ── Progress / duration queries (#625) ──────────────────────────
    //
    // All pure reads of the current state — no mutation, no dependency
    // on the tick. `elapsed()` / `clipDuration()` / `progress()` work in
    // CLIP-TIME (the animation's own `timer`/`frame` clock, which the
    // speed-scaled tick advances), so they're speed-INDEPENDENT. Only
    // `duration()` folds `speed` in to report wall-clock seconds.

    /// `true` once a `.once` clip has played through to its last frame
    /// (alias of `isFinished`, named per #625). `.loop` / `.ping_pong`
    /// never complete; a zero-frame clip never completes.
    pub fn isComplete(self: *const SpriteAnimation) bool {
        return self.isFinished();
    }

    /// Effective playback rate: `speed` when positive, else `0` (paused).
    /// Negative `speed` is paused, never reverse (see the field doc).
    /// Single source of truth for the clamped rate — the tick multiplies
    /// `dt` by this, and `duration()` divides by it.
    pub fn effectiveSpeed(self: *const SpriteAnimation) f32 {
        return if (self.speed > 0) self.speed else 0;
    }

    /// Clip-seconds a single frame is shown at `fps` (speed-independent).
    /// `0` for a degenerate `fps <= 0`.
    pub fn frameDuration(self: *const SpriteAnimation) f32 {
        if (self.fps <= 0) return 0;
        return 1.0 / self.fps;
    }

    /// Intrinsic clip length in clip-seconds: `frames.len / fps`
    /// (speed-independent — the span `timer`/`frame` measure against).
    /// `0` for a degenerate clip (no frames or `fps <= 0`).
    pub fn clipDuration(self: *const SpriteAnimation) f32 {
        return @as(f32, @floatFromInt(self.frames.len)) * self.frameDuration();
    }

    /// Total clip play time in WALL-CLOCK seconds, adjusted by `speed`:
    /// `clipDuration() / speed`. At `speed = 2` a 1s clip reports `0.5s`.
    /// When paused (`speed <= 0`) there IS no finite wall-clock duration,
    /// so this reports the intrinsic `clipDuration()` (the `speed = 1`
    /// length) rather than infinity. `0` for a degenerate clip.
    pub fn duration(self: *const SpriteAnimation) f32 {
        const s = self.effectiveSpeed();
        if (s <= 0) return self.clipDuration();
        return self.clipDuration() / s;
    }

    /// Clip-seconds consumed so far: `frame * frameDuration + timer`
    /// (speed-independent). For a looping clip this ramps 0 → clip length
    /// each cycle; for `.ping_pong` it tracks the current frame position.
    pub fn elapsed(self: *const SpriteAnimation) f32 {
        return @as(f32, @floatFromInt(self.frame)) * self.frameDuration() + self.timer;
    }

    /// Playback progress in `[0, 1]`: `elapsed() / clipDuration()`,
    /// clamped. Speed-independent (both terms are clip-time). Returns
    /// exactly `1.0` once `isComplete()` (a finished `.once` clip lands
    /// on its last frame with `timer` short of a full frame, so the raw
    /// ratio would read just under 1). `0` for a degenerate clip.
    pub fn progress(self: *const SpriteAnimation) f32 {
        if (self.isComplete()) return 1.0;
        const total = self.clipDuration();
        if (total <= 0) return 0;
        return std.math.clamp(self.elapsed() / total, 0, 1);
    }
};
