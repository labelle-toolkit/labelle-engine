//! SpriteAnimation tick system tests — drives the ECS layer that the
//! `sprite_animation.advance` state machine sits underneath.
//!
//! Uses the same MockEcs + StubRender harness the save/load mixin
//! tests use. `StubRender.Sprite` carries only `sprite_name` / `visible`
//! / `z_index` — no `source_rect` / `texture` — so the tick's atlas
//! resolution branch is a no-op in these tests (guarded by
//! `@hasField`). That still lets us verify the critical behaviour:
//! frame flip → `sprite_name` rewritten; idle tick → `sprite_name`
//! unchanged.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const core = @import("labelle-core");

const SpriteAnimation = engine.SpriteAnimation;
const spriteAnimationTick = engine.spriteAnimationTick;

const game_mod = engine.game_mod;
const scene_mod = engine.scene_mod;
const ComponentRegistry = scene_mod.ComponentRegistry;

// Minimal registry — the tick system only needs SpriteAnimation to
// be attachable to entities; it looks up the Sprite through the
// renderer's `SpriteComp` alias, not the registry.
const TestComponents = ComponentRegistry(.{
    .SpriteAnimation = SpriteAnimation,
});

const MockEcs = core.MockEcsBackend(u32);
const TestGame = game_mod.GameConfig(
    core.StubRender(MockEcs.Entity),
    MockEcs,
    engine.input_mod.StubInput,
    engine.audio_mod.StubAudio,
    engine.gui_mod.StubGui,
    void,
    core.StubLogSink,
    TestComponents,
    &.{},
    void,
);

const Sprite = TestGame.SpriteComp;

const frames = [3][]const u8{ "a.png", "b.png", "c.png" };

test "tick: advances sprite_name on frame flip" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const entity = game.createEntity();
    game.active_world.ecs_backend.addComponent(entity, Sprite{ .sprite_name = "a.png" });
    game.active_world.ecs_backend.addComponent(entity, SpriteAnimation{
        .frames = &frames,
        .fps = 6,
        .mode = .loop,
    });

    // One frame duration at 6 fps → tick flips frame 0 → 1.
    spriteAnimationTick(&game, 1.0 / 6.0);

    const sprite = game.active_world.ecs_backend.getComponent(entity, Sprite).?;
    try testing.expectEqualStrings("b.png", sprite.sprite_name);
    const anim = game.active_world.ecs_backend.getComponent(entity, SpriteAnimation).?;
    try testing.expectEqual(@as(u8, 1), anim.frame);
}

test "tick: idle ticks (sub-frame dt) do not write sprite_name" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const entity = game.createEntity();
    game.active_world.ecs_backend.addComponent(entity, Sprite{ .sprite_name = "initial.png" });
    game.active_world.ecs_backend.addComponent(entity, SpriteAnimation{
        .frames = &frames,
        .fps = 6,
        .mode = .loop,
    });

    // Half-frame dt: timer accumulates, no frame flip, sprite_name
    // stays at "initial.png" — the tick must not write even the
    // frame-0 sprite over an entity's pre-existing name. Regression
    // guard: a naive "always sync" implementation would clobber
    // "initial.png" with "a.png" (frame 0) on the first tick.
    spriteAnimationTick(&game, 1.0 / 12.0);

    const sprite = game.active_world.ecs_backend.getComponent(entity, Sprite).?;
    try testing.expectEqualStrings("initial.png", sprite.sprite_name);
}

test "tick: entity without SpriteAnimation is skipped" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const decorated = game.createEntity();
    game.active_world.ecs_backend.addComponent(decorated, Sprite{ .sprite_name = "a.png" });
    game.active_world.ecs_backend.addComponent(decorated, SpriteAnimation{
        .frames = &frames,
        .fps = 6,
        .mode = .loop,
    });

    const bare = game.createEntity();
    game.active_world.ecs_backend.addComponent(bare, Sprite{ .sprite_name = "unchanged.png" });

    spriteAnimationTick(&game, 1.0 / 6.0);

    const dec = game.active_world.ecs_backend.getComponent(decorated, Sprite).?;
    try testing.expectEqualStrings("b.png", dec.sprite_name);
    const br = game.active_world.ecs_backend.getComponent(bare, Sprite).?;
    try testing.expectEqualStrings("unchanged.png", br.sprite_name);
}

test "tick: entity with SpriteAnimation but no Sprite is skipped" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    // No Sprite attached. The tick's view filter is {SpriteAnimation,
    // Sprite} so this entity shouldn't appear at all — the test is
    // a regression guard against someone loosening the filter to
    // `.{SpriteAnimation}` and then crashing on the orphan.
    const entity = game.createEntity();
    game.active_world.ecs_backend.addComponent(entity, SpriteAnimation{
        .frames = &frames,
        .fps = 6,
        .mode = .loop,
    });

    spriteAnimationTick(&game, 1.0 / 6.0);

    const anim = game.active_world.ecs_backend.getComponent(entity, SpriteAnimation).?;
    // Timer didn't advance because the view filter excluded the entity.
    try testing.expectEqual(@as(f32, 0), anim.timer);
    try testing.expectEqual(@as(u8, 0), anim.frame);
}

test "tick: once mode stops writing on the last frame" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const entity = game.createEntity();
    game.active_world.ecs_backend.addComponent(entity, Sprite{ .sprite_name = "" });
    game.active_world.ecs_backend.addComponent(entity, SpriteAnimation{
        .frames = &frames,
        .fps = 6,
        .mode = .once,
    });

    // 0.5 sec at 6 fps = 3 frames → cycle ends on last frame (c.png).
    spriteAnimationTick(&game, 0.5);
    const sprite = game.active_world.ecs_backend.getComponent(entity, Sprite).?;
    try testing.expectEqualStrings("c.png", sprite.sprite_name);

    // Further ticks: frame stays at 2, sprite_name stays at c.png.
    // The `advance` flag returns false; no write, no markVisualDirty.
    spriteAnimationTick(&game, 10.0);
    try testing.expectEqualStrings("c.png", sprite.sprite_name);
    const anim = game.active_world.ecs_backend.getComponent(entity, SpriteAnimation).?;
    try testing.expectEqual(@as(u8, 2), anim.frame);
}

test "tick: multiple entities advance independently" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const a = game.createEntity();
    game.active_world.ecs_backend.addComponent(a, Sprite{ .sprite_name = "" });
    game.active_world.ecs_backend.addComponent(a, SpriteAnimation{
        .frames = &frames,
        .fps = 6,
        .mode = .loop,
    });

    const b = game.createEntity();
    game.active_world.ecs_backend.addComponent(b, Sprite{ .sprite_name = "" });
    game.active_world.ecs_backend.addComponent(b, SpriteAnimation{
        .frames = &frames,
        .fps = 12, // twice as fast
        .mode = .loop,
    });

    spriteAnimationTick(&game, 1.0 / 6.0);

    const sa = game.active_world.ecs_backend.getComponent(a, Sprite).?;
    const sb = game.active_world.ecs_backend.getComponent(b, Sprite).?;
    // a advances 1 frame at 6 fps: a.png → b.png
    try testing.expectEqualStrings("b.png", sa.sprite_name);
    // b advances 2 frames at 12 fps: a.png → b.png → c.png
    try testing.expectEqualStrings("c.png", sb.sprite_name);
}
