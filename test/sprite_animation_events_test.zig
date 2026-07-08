//! SpriteAnimation playback events end-to-end (#625).
//!
//! Drives the `sprite_animation_tick` against a Game whose `GameEvents`
//! declares the three `engine__anim_*` variants and a recorder hook, then
//! drains `dispatchEvents` to observe what the tick forwarded:
//!
//!   engine__anim_frame     — landed on a frame listed in `event_frames`
//!   engine__anim_complete  — a `.once` clip reached its last frame
//!   engine__anim_loop      — a `.loop` wrap / `.ping_pong` reversal
//!
//! The forwarding is comptime-gated on `@hasField(GameEvents, tag)`, so an
//! events-less game (`GameEvents = void`) never enters this path — that
//! zero-cost case is covered by `sprite_animation_tick_test.zig`, which
//! runs the identical tick with no events union.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const core = @import("labelle-core");

const SpriteAnimation = engine.SpriteAnimation;
const spriteAnimationTick = engine.spriteAnimationTick;

const game_mod = engine.game_mod;
const scene_mod = engine.scene_mod;
const ComponentRegistry = scene_mod.ComponentRegistry;

const TestComponents = ComponentRegistry(.{
    .SpriteAnimation = SpriteAnimation,
});

const MockEcs = core.MockEcsBackend(u32);

// ── GameEvents union with the three playback variants ──────────────
const AnimGameEvents = union(enum) {
    engine__anim_frame: engine.Events.anim_frame,
    engine__anim_complete: engine.Events.anim_complete,
    engine__anim_loop: engine.Events.anim_loop,
};

// ── Recorder hook ──────────────────────────────────────────────────
const Recorder = struct {
    frame_count: usize = 0,
    complete_count: usize = 0,
    loop_count: usize = 0,

    last_frame_entity: u32 = 0,
    last_frame_index: u8 = 255,
    last_complete_entity: u32 = 0,
    last_loop_repetition: u16 = 0,

    pub fn engine__anim_frame(self: *Recorder, info: anytype) void {
        self.frame_count += 1;
        self.last_frame_entity = info.entity;
        self.last_frame_index = info.frame;
    }
    pub fn engine__anim_complete(self: *Recorder, info: anytype) void {
        self.complete_count += 1;
        self.last_complete_entity = info.entity;
    }
    pub fn engine__anim_loop(self: *Recorder, info: anytype) void {
        self.loop_count += 1;
        self.last_loop_repetition = info.repetition;
    }
};

const AnimGame = game_mod.GameConfig(
    core.StubRender(MockEcs.Entity),
    MockEcs,
    engine.input_mod.StubInput,
    engine.audio_mod.StubAudio,
    engine.StubVideo,
    engine.gui_mod.StubGui,
    *Recorder,
    core.StubLogSink,
    TestComponents,
    &.{},
    AnimGameEvents,
);

const Sprite = AnimGame.SpriteComp;
const frames = [4][]const u8{ "a.png", "b.png", "c.png", "d.png" };

fn newGame(recorder: *Recorder) AnimGame {
    var game = AnimGame.init(testing.allocator);
    game.setHooks(recorder);
    game.dispatchEvents();
    recorder.* = .{};
    return game;
}

test "tick: landing on an event frame emits engine__anim_frame with entity + index" {
    var recorder = Recorder{};
    var game = newGame(&recorder);
    defer game.deinit();

    const marked = [_]u16{2};
    const entity = game.createEntity();
    game.active_world.ecs_backend.addComponent(entity, Sprite{ .sprite_name = "a.png" });
    game.active_world.ecs_backend.addComponent(entity, SpriteAnimation{
        .frames = &frames,
        .fps = 6,
        .mode = .loop,
        .event_frames = &marked,
    });

    // Advance straight to frame 2.
    spriteAnimationTick(&game, 2.0 / 6.0);
    game.dispatchEvents();

    try testing.expectEqual(@as(usize, 1), recorder.frame_count);
    try testing.expectEqual(entity, recorder.last_frame_entity);
    try testing.expectEqual(@as(u8, 2), recorder.last_frame_index);
    try testing.expectEqual(@as(usize, 0), recorder.complete_count);
}

test "tick: a .once clip emits engine__anim_complete exactly once" {
    var recorder = Recorder{};
    var game = newGame(&recorder);
    defer game.deinit();

    const entity = game.createEntity();
    game.active_world.ecs_backend.addComponent(entity, Sprite{ .sprite_name = "a.png" });
    game.active_world.ecs_backend.addComponent(entity, SpriteAnimation{
        .frames = &frames,
        .fps = 6,
        .mode = .once,
    });

    spriteAnimationTick(&game, 1.0); // run through all 4 frames
    game.dispatchEvents();
    try testing.expectEqual(@as(usize, 1), recorder.complete_count);
    try testing.expectEqual(entity, recorder.last_complete_entity);

    // Further ticks: no re-fire (frame is parked on the last one).
    spriteAnimationTick(&game, 10.0);
    game.dispatchEvents();
    try testing.expectEqual(@as(usize, 1), recorder.complete_count);
}

test "tick: a .loop wrap emits engine__anim_loop with the repetition count" {
    var recorder = Recorder{};
    var game = newGame(&recorder);
    defer game.deinit();

    const entity = game.createEntity();
    game.active_world.ecs_backend.addComponent(entity, Sprite{ .sprite_name = "a.png" });
    game.active_world.ecs_backend.addComponent(entity, SpriteAnimation{
        .frames = &frames,
        .fps = 6,
        .mode = .loop,
    });

    // 4 frames @ 6 fps → one wrap after 4/6 s of play from frame 0.
    spriteAnimationTick(&game, 4.0 / 6.0);
    game.dispatchEvents();
    try testing.expectEqual(@as(usize, 1), recorder.loop_count);
    try testing.expectEqual(@as(u16, 1), recorder.last_loop_repetition);
}

test "tick: speed 2 advances twice as fast; speed 0 pauses" {
    var recorder = Recorder{};
    var game = newGame(&recorder);
    defer game.deinit();

    const fast = game.createEntity();
    game.active_world.ecs_backend.addComponent(fast, Sprite{ .sprite_name = "a.png" });
    game.active_world.ecs_backend.addComponent(fast, SpriteAnimation{
        .frames = &frames,
        .fps = 6,
        .mode = .loop,
        .speed = 2.0,
    });

    const paused = game.createEntity();
    game.active_world.ecs_backend.addComponent(paused, Sprite{ .sprite_name = "a.png" });
    game.active_world.ecs_backend.addComponent(paused, SpriteAnimation{
        .frames = &frames,
        .fps = 6,
        .mode = .loop,
        .speed = 0,
    });

    // One frame-duration of dt. At speed 2 the fast clip advances 2
    // frames (a → c); the paused clip does not move.
    spriteAnimationTick(&game, 1.0 / 6.0);

    const fa = game.active_world.ecs_backend.getComponent(fast, SpriteAnimation).?;
    try testing.expectEqual(@as(u8, 2), fa.frame);
    const pa = game.active_world.ecs_backend.getComponent(paused, SpriteAnimation).?;
    try testing.expectEqual(@as(u8, 0), pa.frame);
    try testing.expectEqual(@as(f32, 0), pa.timer);
}

test "tick: negative speed is treated as paused, not reverse" {
    var recorder = Recorder{};
    var game = newGame(&recorder);
    defer game.deinit();

    const entity = game.createEntity();
    game.active_world.ecs_backend.addComponent(entity, Sprite{ .sprite_name = "a.png" });
    game.active_world.ecs_backend.addComponent(entity, SpriteAnimation{
        .frames = &frames,
        .fps = 6,
        .mode = .loop,
        .speed = -3.0,
    });

    spriteAnimationTick(&game, 1.0);
    const anim = game.active_world.ecs_backend.getComponent(entity, SpriteAnimation).?;
    try testing.expectEqual(@as(u8, 0), anim.frame);
    try testing.expectEqual(@as(f32, 0), anim.timer);
}
