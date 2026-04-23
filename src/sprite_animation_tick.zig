//! SpriteAnimation ECS tick system (Phase A+ of RFC-PREFAB-ANIMATION.md).
//!
//! Walks entities that have both `SpriteAnimation` + the renderer's
//! Sprite component, advances the animation state, and writes the new
//! frame's `sprite_name` / `source_rect` / `texture` onto the Sprite
//! on frame flips. Idle entities (same frame as last tick) write
//! nothing — `advance` returns a changed-flag the tick uses to
//! short-circuit.
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
/// - On a frame flip, `Sprite.sprite_name` is set to the resolved
///   frame name. If `game.findSprite(name)` returns a valid atlas
///   entry, `source_rect` + `texture` are updated too; otherwise
///   those are left alone (the missing-atlas case — frame name
///   written, but no texture resolution — is acceptable for tests
///   and for the brief window while an atlas loads).
/// - `markVisualDirty(entity)` fires on frame flip only. Idle ticks
///   write nothing, produce no dirty signal, and cost only the
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

        // Atlas resolution — optional, guarded by `@hasField` so the
        // tick compiles against `StubRender` (which only carries
        // `sprite_name` / `visible` / `z_index` for engine-level
        // tests) as well as the full labelle-gfx Sprite (with
        // `source_rect` + `texture`). Skipping resolution on a
        // stub-render build means the frame name advances but
        // textures don't bind — correct for unit tests, inert in
        // release because every shipping game uses the full Sprite.
        if (comptime @hasField(Sprite, "source_rect") and @hasField(Sprite, "texture")) {
            if (game.findSprite(new_name)) |result| {
                sprite.source_rect = .{
                    .x = @floatFromInt(result.sprite.x),
                    .y = @floatFromInt(result.sprite.y),
                    .width = @floatFromInt(result.sprite.getWidth()),
                    .height = @floatFromInt(result.sprite.getHeight()),
                };
                sprite.texture = @enumFromInt(result.texture_id);
            }
        }

        // `markVisualDirty` is the contract every renderer plugin
        // exposes per `core.RenderInterface`, so this is always safe
        // to call — no `@hasDecl` gate needed.
        game.renderer.markVisualDirty(entity);
    }
}
