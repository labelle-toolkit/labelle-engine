//! Tests for engine-driven sprite animation (opt-in).
//!
//! When `drive_sprite_animations` is on, the engine advances every
//! `SpriteAnimation` component itself inside `tick()` (on the time-scaled
//! dt) — the game no longer needs a `sprite_animation_tick` script.
//! `setSpriteAnimationsPaused(true)` freezes that advance, which is how a
//! pause menu stops sprite cycling without gating a per-frame script.
//!
//! Uses the in-tree `Game = GameWith(void)` (MockEcsBackend + StubRender,
//! whose `Sprite` carries a writable `sprite_name`).

const std = @import("std");
const testing = std.testing;

const engine = @import("engine");
const Game = engine.Game;
const SpriteAnimation = engine.SpriteAnimation;

const FRAMES = [_][]const u8{ "f0", "f1", "f2" };

fn makeAnimatedEntity(game: *Game) Game.EntityType {
    const e = game.createEntity();
    // fps=10 → 0.1 s/frame, so a 0.2 s tick advances exactly 2 frames.
    game.addComponent(e, SpriteAnimation{ .frames = FRAMES[0..], .fps = 10 });
    game.addComponent(e, Game.SpriteComp{ .sprite_name = "f0" });
    return e;
}

// ── Flag surface ────────────────────────────────────────────────────

test "drive/pause flags default off and round-trip" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    try testing.expect(!game.spriteAnimationsPaused());
    game.setDriveSpriteAnimations(true);
    game.setSpriteAnimationsPaused(true);
    try testing.expect(game.spriteAnimationsPaused());
    game.setSpriteAnimationsPaused(false);
    try testing.expect(!game.spriteAnimationsPaused());
}

// ── Behaviour through tick() ────────────────────────────────────────

test "tick does not advance sprite animation unless driving is enabled" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    const e = makeAnimatedEntity(&game);

    // Driving off (default): the engine must not touch the animation.
    game.tick(0.2);
    const anim = game.getComponent(e, SpriteAnimation).?;
    try testing.expectEqual(@as(u8, 0), anim.frame);
}

test "tick advances sprite animation when driving is enabled" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    const e = makeAnimatedEntity(&game);
    game.setDriveSpriteAnimations(true);

    game.tick(0.2); // 2 frames at fps=10
    const anim = game.getComponent(e, SpriteAnimation).?;
    try testing.expectEqual(@as(u8, 2), anim.frame);

    const sprite = game.getComponent(e, Game.SpriteComp).?;
    try testing.expectEqualStrings("f2", sprite.sprite_name);
}

test "paused freezes the advance and resume continues it" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    const e = makeAnimatedEntity(&game);
    game.setDriveSpriteAnimations(true);

    game.tick(0.1); // → frame 1
    try testing.expectEqual(@as(u8, 1), game.getComponent(e, SpriteAnimation).?.frame);

    game.setSpriteAnimationsPaused(true);
    game.tick(0.2); // frozen — no advance
    try testing.expectEqual(@as(u8, 1), game.getComponent(e, SpriteAnimation).?.frame);

    game.setSpriteAnimationsPaused(false);
    game.tick(0.1); // → frame 2
    try testing.expectEqual(@as(u8, 2), game.getComponent(e, SpriteAnimation).?.frame);
}
