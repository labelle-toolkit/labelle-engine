//! SpriteAnimation ECS tick system (Phase A+ of RFC-PREFAB-ANIMATION.md).
//!
//! Walks entities that have both `SpriteAnimation` + the renderer's
//! Sprite component, advances the animation state, and writes the new
//! frame's `sprite_name` onto the Sprite on frame flips. Idle entities
//! (same frame as last tick) write nothing — `advance` returns a
//! changed-flag the tick uses to short-circuit.
//!
//! ## Atlas resolution is delegated
//!
//! This tick only writes `sprite_name`. Mapping that name to
//! `source_rect` + `texture` + `display_*` + rotation handling is
//! `Game.resolveAtlasSprites`'s job (src/game.zig) — it runs every
//! frame before renderer sync, uses the per-entity `sprite_cache`,
//! and marks the entity visually dirty only on cache miss. Writing
//! `sprite_name` here is enough to invalidate that cache on the next
//! frame, so the canonical resolver picks up the change and handles
//! rotated atlases, per-axis `texture_scale`, and `display_width/
//! height` correctly — features a reimplementation here would either
//! duplicate or get subtly wrong.
//!
//! Generic over the game type, same shape `save_load_mixin` uses.
//! Called once per frame from the game's scene-tick slot, or auto-
//! wired by the assembler in the future.
//!
//! The pure state-machine half (the `SpriteAnimation` struct +
//! `advance(dt)`) lives in `sprite_animation.zig`; see the RFC for
//! the full motivation and the staging rationale for splitting these
//! across two files (and two PRs).

const SpriteAnimation = @import("sprite_animation.zig").SpriteAnimation;
const anim_events = @import("animation_events.zig");

/// Advance all `SpriteAnimation` components by `dt` and update their
/// sibling Sprite on frame flips.
///
/// Semantics:
/// - `dt` is the time-scaled frame delta. Each animation's per-clip
///   `speed` (#625) is applied ON TOP here (`dt * max(0, speed)`), so a
///   `speed = 2` clip advances twice as fast and `speed <= 0` pauses it
///   (negative is paused, never reverse).
/// - Entities without both `SpriteAnimation` and `Sprite` are skipped.
/// - On a frame flip, `Sprite.sprite_name` is written. Atlas fields
///   (`source_rect`, `texture`, `display_*`) are NOT touched here —
///   `Game.resolveAtlasSprites` handles the full atlas mapping
///   before renderer sync, including rotation and per-axis texture
///   scaling.
/// - Idle ticks (sub-frame `dt`) write nothing and cost only the
///   timer bookkeeping inside `advance`.
///
/// ## Playback events (#625)
///
/// When the project's `GameEvents` declares any of `engine__anim_frame`
/// / `engine__anim_complete` / `engine__anim_loop`, the tick advances
/// through `advanceEvents` and forwards the queued lifecycle / frame-cue
/// events to `game.emit` (buffered; drained end-of-frame), injecting the
/// entity the pure `advance` methods don't know. When NONE are wanted the
/// whole events path folds away at comptime and the tick uses the plain
/// `advance` — an events-less game pays nothing.
pub fn tick(game: anytype, dt: f32) void {
    const Game = @TypeOf(game.*);
    const Sprite = Game.SpriteComp;

    // Queue ONLY the event kinds this project declared. A project that
    // listens to just `anim_frame` must not have its fixed `PendingBuf`
    // filled with `loop_end` events from a multi-wrap tick (which would
    // crowd out / drop the frame events it wants). The mask is comptime,
    // so unwanted kinds are never even queued.
    const mask = comptime SpriteAnimation.EventMask{
        .frame = Game.engineEventWanted("engine__anim_frame"),
        .clip_end = Game.engineEventWanted("engine__anim_complete"),
        .loop_end = Game.engineEventWanted("engine__anim_loop"),
    };
    const events_wanted = comptime mask.frame or mask.clip_end or mask.loop_end;

    var view = game.ecs_backend.view(.{ SpriteAnimation, Sprite }, .{});
    defer view.deinit();

    while (view.next()) |entity| {
        const anim = game.ecs_backend.getComponent(entity, SpriteAnimation) orelse continue;

        // Per-clip playback speed on top of the (already time-scaled) dt.
        // `effectiveSpeed()`: 0 / negative → paused, never reverse.
        const eff_dt = dt * anim.effectiveSpeed();

        const changed = if (comptime events_wanted) blk: {
            var buf: anim_events.PendingBuf = .{};
            const c = anim.advanceEventsMasked(eff_dt, &buf, mask);
            // Most ticks queue nothing (sub-frame or an event-less frame);
            // skip the entity cast + slice walk unless something fired.
            if (buf.len > 0) forwardEvents(game, entity, &buf);
            break :blk c;
        } else anim.advance(eff_dt);

        if (!changed) continue;

        const new_name = anim.currentSprite() orelse continue;
        const sprite = game.ecs_backend.getComponent(entity, Sprite) orelse continue;
        sprite.sprite_name = new_name;

        // On atlas builds `resolveAtlasSprites` will also dirty the
        // entity on its cache miss later this frame — harmless
        // double-dirty. On stub or sprite-by-name renderers where
        // `resolveAtlasSprites` is a comptime no-op, this is the
        // only place the visual change gets signalled, so the call
        // has to stay here rather than being pushed downstream.
        game.renderer.markVisualDirty(entity);
    }
}

/// Forward the entity-less `PendingBuf` produced by `advanceEvents` to
/// the game's buffered event bus, mapping each `PendingKind` onto its
/// `engine__anim_*` variant and injecting the entity. `emitEngineEvent`
/// folds away per-tag when a given variant isn't declared, so a project
/// that listens to only one of the three pays for only that one.
fn forwardEvents(game: anytype, entity: anytype, buf: *const anim_events.PendingBuf) void {
    const id: u32 = @intCast(entity);
    for (buf.slice()) |e| {
        switch (e.kind) {
            .marker => game.emitEngineEvent("engine__anim_frame", .{ .entity = id, .frame = e.frame }),
            .clip_end => game.emitEngineEvent("engine__anim_complete", .{ .entity = id }),
            .loop_end => game.emitEngineEvent("engine__anim_loop", .{ .entity = id, .repetition = e.repetition }),
        }
    }
}
