const std = @import("std");
const engine = @import("engine");
const t = std.testing;
const Game = engine.Game;
const frames = [_][]const u8{ "a", "b", "c", "d" };

fn add(game: *Game) Game.EntityType {
    const e = game.createEntity();
    game.addComponent(e, engine.SpriteAnimation{ .frames = &frames, .fps = 4 });
    game.addComponent(e, Game.SpriteComp{ .sprite_name = "a" });
    game.setDriveSpriteAnimations(true);
    return e;
}

test "audit: explicit pause flag freezes clock but still advances sprite" {
    var game = Game.init(t.allocator);
    defer game.deinit();
    const e = add(&game);
    game.setPaused(true);
    const clock = game.elapsedSeconds();
    game.tick(0.25);
    try t.expect(game.isPaused());
    try t.expectEqual(clock, game.elapsedSeconds());
    try t.expectEqual(@as(u8, 1), game.getComponent(e, engine.SpriteAnimation).?.frame);
}

test "audit: zero scale does freeze sprite" {
    var game = Game.init(t.allocator);
    defer game.deinit();
    const e = add(&game);
    game.setTimeScale(0);
    game.tick(0.25);
    try t.expectEqual(@as(u8, 0), game.getComponent(e, engine.SpriteAnimation).?.frame);
}

test "audit: pause and resume lose the earlier slow motion scale" {
    var game = Game.init(t.allocator);
    defer game.deinit();
    game.setTimeScale(0.5);
    game.pause();
    game.resume_();
    try t.expectEqual(@as(f32, 1), game.time_scale);
}

test "audit: legacy cue crossed without landing is absent" {
    var anim = engine.SpriteAnimation{ .frames = &frames, .fps = 4, .event_frames = &.{1} };
    var buf: engine.AnimPendingBuf = .{};
    _ = anim.advanceEvents(0.5, &buf);
    try t.expectEqual(@as(u8, 2), anim.frame);
    try t.expectEqual(@as(u8, 0), buf.len);
}

test "audit: 40 sprite loops preserve repetition but cap delivery at 32" {
    var anim = engine.SpriteAnimation{ .frames = &frames, .fps = 4 };
    var buf: engine.AnimPendingBuf = .{};
    _ = anim.advanceEvents(40, &buf);
    try t.expectEqual(@as(u16, 40), anim.repetition);
    try t.expectEqual(@as(u8, 32), buf.len);
}

test "audit: AnimationDef reference cannot deliver all crossed markers" {
    const Def = engine.AnimationDef(.{
        .variants = .{"hero"},
        .clips = .{ .pulse = .{ .frames = .{ .{ .f = 1, .marker = "pulse" }, 2 }, .mode = .time, .speed = 1.0 } },
    });
    var state: engine.AnimationState = .{ .clip = 0, .frame_count = 2, .speed = 1, .mode = .time };
    var buf: engine.AnimPendingBuf = .{};
    Def.advanceStateEvents(&state, 100, &buf);
    var markers: usize = 0;
    for (buf.slice()) |event| {
        if (event.kind == .marker) markers += 1;
    }
    try t.expectEqual(@as(u16, 50), state.repetition);
    try t.expectEqual(@as(u8, 32), buf.len);
    try t.expect(markers < 51); // Entry marker plus 50 loop entries.
}
