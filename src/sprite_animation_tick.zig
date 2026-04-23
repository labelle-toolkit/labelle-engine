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

/// Advance all `SpriteAnimation` components by `dt` and update their
/// sibling Sprite on frame flips.
///
/// Semantics:
/// - Entities without both `SpriteAnimation` and `Sprite` are skipped.
/// - On a frame flip, `Sprite.sprite_name` is written. Atlas fields
///   (`source_rect`, `texture`, `display_*`) are NOT touched here —
///   `Game.resolveAtlasSprites` handles the full atlas mapping
///   before renderer sync, including rotation and per-axis texture
///   scaling.
/// - Idle ticks (sub-frame `dt`) write nothing and cost only the
///   timer bookkeeping inside `advance`.
pub fn tick(game: anytype, dt: f32) void {
    const Game = @TypeOf(game.*);
    const Sprite = Game.SpriteComp;

    var view = game.ecs_backend.view(.{ SpriteAnimation, Sprite }, .{});
    defer view.deinit();

    while (view.next()) |entity| {
        const anim = game.ecs_backend.getComponent(entity, SpriteAnimation) orelse continue;
        if (!anim.advance(dt)) continue;

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
