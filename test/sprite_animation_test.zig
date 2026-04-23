//! SpriteAnimation state machine tests.
//! Covers .loop / .once / .ping_pong modes, degenerate inputs, and the
//! save-policy contract. The ECS tick system that consumes these
//! components is tested separately once that lands.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const core = @import("labelle-core");

const SpriteAnimation = engine.SpriteAnimation;

const pipe_frames = [6][]const u8{
    "pipe_0001.png",
    "pipe_0002.png",
    "pipe_0003.png",
    "pipe_0004.png",
    "pipe_0005.png",
    "pipe_0006.png",
};

test "SpriteAnimation: loop mode cycles through frames" {
    var anim = SpriteAnimation{
        .frames = &pipe_frames,
        .fps = 6,
        .mode = .loop,
    };
    // One full cycle = 6 frames / 6 fps = 1 second.
    // At dt=1/6, advance one frame per call.
    const step: f32 = 1.0 / 6.0;

    try testing.expectEqual(@as(u8, 0), anim.frame);
    try testing.expect(anim.advance(step));
    try testing.expectEqual(@as(u8, 1), anim.frame);
    try testing.expect(anim.advance(step));
    try testing.expectEqual(@as(u8, 2), anim.frame);
    try testing.expect(anim.advance(step * 3));
    try testing.expectEqual(@as(u8, 5), anim.frame);
    try testing.expect(anim.advance(step));
    try testing.expectEqual(@as(u8, 0), anim.frame); // wrapped
}

test "SpriteAnimation: loop mode is idempotent within a frame" {
    var anim = SpriteAnimation{
        .frames = &pipe_frames,
        .fps = 6,
        .mode = .loop,
    };
    // Half-step: timer accumulates but no frame change.
    const half_step: f32 = 1.0 / 12.0;
    try testing.expect(!anim.advance(half_step));
    try testing.expectEqual(@as(u8, 0), anim.frame);
    // Another half: now total 1 frame → flips.
    try testing.expect(anim.advance(half_step));
    try testing.expectEqual(@as(u8, 1), anim.frame);
}

test "SpriteAnimation: once mode stops on the last frame" {
    var anim = SpriteAnimation{
        .frames = &pipe_frames,
        .fps = 6,
        .mode = .once,
    };
    // Full cycle: should land on the last frame (index 5).
    try testing.expect(anim.advance(1.0));
    try testing.expectEqual(@as(u8, 5), anim.frame);
    // Further advance does not wrap or restart.
    try testing.expect(!anim.advance(1.0));
    try testing.expectEqual(@as(u8, 5), anim.frame);
    try testing.expect(!anim.advance(10.0));
    try testing.expectEqual(@as(u8, 5), anim.frame);
}

test "SpriteAnimation: ping_pong reverses at endpoints" {
    var anim = SpriteAnimation{
        .frames = &pipe_frames,
        .fps = 6,
        .mode = .ping_pong,
    };
    const step: f32 = 1.0 / 6.0;

    // Forward: 0 → 1 → 2 → 3 → 4 → 5
    for (1..6) |expected_frame| {
        try testing.expect(anim.advance(step));
        try testing.expectEqual(@as(u8, @intCast(expected_frame)), anim.frame);
    }
    try testing.expect(anim.forward);

    // At 5, next step reverses: 5 → 4 → 3 → 2 → 1 → 0
    const expected_reverse = [_]u8{ 4, 3, 2, 1, 0 };
    for (expected_reverse) |expected_frame| {
        try testing.expect(anim.advance(step));
        try testing.expectEqual(expected_frame, anim.frame);
    }
    try testing.expect(!anim.forward);

    // At 0, next step flips forward again: 0 → 1
    try testing.expect(anim.advance(step));
    try testing.expectEqual(@as(u8, 1), anim.frame);
    try testing.expect(anim.forward);
}

test "SpriteAnimation: ping_pong with single frame is stationary" {
    const single = [1][]const u8{"only.png"};
    var anim = SpriteAnimation{
        .frames = &single,
        .fps = 6,
        .mode = .ping_pong,
    };
    try testing.expect(!anim.advance(10.0));
    try testing.expectEqual(@as(u8, 0), anim.frame);
}

test "SpriteAnimation: degenerate zero-frame animation is a no-op" {
    const empty: []const []const u8 = &.{};
    var anim = SpriteAnimation{
        .frames = empty,
        .fps = 6,
        .mode = .loop,
    };
    try testing.expect(!anim.advance(10.0));
    try testing.expectEqual(@as(u8, 0), anim.frame);
}

test "SpriteAnimation: zero fps is a no-op" {
    var anim = SpriteAnimation{
        .frames = &pipe_frames,
        .fps = 0,
        .mode = .loop,
    };
    try testing.expect(!anim.advance(10.0));
    try testing.expectEqual(@as(u8, 0), anim.frame);
}

test "SpriteAnimation: large dt covers multiple frames in one call" {
    var anim = SpriteAnimation{
        .frames = &pipe_frames,
        .fps = 6,
        .mode = .loop,
    };
    // 2.5 seconds at 6 fps = 15 frames. 15 mod 6 = 3.
    try testing.expect(anim.advance(2.5));
    try testing.expectEqual(@as(u8, 3), anim.frame);
}

test "SpriteAnimation: save policy is transient — comes back via prefab respawn" {
    try testing.expect(core.hasSavePolicy(SpriteAnimation));
    // `.transient` is intentional. `frames: []const []const u8` isn't
    // serde-writable, and the prefab-foundations RFC assumes this
    // component is redeclared by the prefab's jsonc on every load —
    // so there's nothing to round-trip through the save file.
    try testing.expectEqual(core.SavePolicy.transient, core.getSavePolicy(SpriteAnimation).?);
}

test "SpriteAnimation: currentSprite returns the expected frame name" {
    var anim = SpriteAnimation{
        .frames = &pipe_frames,
        .fps = 6,
        .mode = .loop,
    };
    try testing.expectEqualStrings("pipe_0001.png", anim.currentSprite().?);
    _ = anim.advance(1.0 / 6.0);
    try testing.expectEqualStrings("pipe_0002.png", anim.currentSprite().?);
}

test "SpriteAnimation: currentSprite on empty frames returns null" {
    const empty: []const []const u8 = &.{};
    const anim = SpriteAnimation{
        .frames = empty,
        .fps = 6,
        .mode = .loop,
    };
    try testing.expect(anim.currentSprite() == null);
}

test "SpriteAnimation: isFinished false for loop and ping_pong" {
    var loop_anim = SpriteAnimation{
        .frames = &pipe_frames,
        .fps = 6,
        .mode = .loop,
    };
    _ = loop_anim.advance(100.0);
    try testing.expect(!loop_anim.isFinished());

    var pp_anim = SpriteAnimation{
        .frames = &pipe_frames,
        .fps = 6,
        .mode = .ping_pong,
    };
    _ = pp_anim.advance(100.0);
    try testing.expect(!pp_anim.isFinished());
}

test "SpriteAnimation: isFinished true after once completes" {
    var anim = SpriteAnimation{
        .frames = &pipe_frames,
        .fps = 6,
        .mode = .once,
    };
    try testing.expect(!anim.isFinished()); // not done at frame 0
    _ = anim.advance(1.0); // advance through all 6 frames
    try testing.expectEqual(@as(u8, 5), anim.frame);
    try testing.expect(anim.isFinished());
    // stays finished after further advances
    _ = anim.advance(10.0);
    try testing.expect(anim.isFinished());
}

test "SpriteAnimation: isFinished false for empty-frame animation" {
    const empty: []const []const u8 = &.{};
    const anim = SpriteAnimation{
        .frames = empty,
        .fps = 6,
        .mode = .once,
    };
    try testing.expect(!anim.isFinished());
}

test "SpriteAnimation: negative dt does not panic" {
    // Regression guard for gemini HIGH feedback on #475: negative
    // `dt` would drive `timer` below zero, and the later signed →
    // unsigned cast in `@intFromFloat(@floor(steps_f))` would trap.
    // The fix clamps `timer` to non-negative before the cast.
    var anim = SpriteAnimation{
        .frames = &pipe_frames,
        .fps = 6,
        .mode = .loop,
    };
    try testing.expect(!anim.advance(-1.0));
    try testing.expectEqual(@as(u8, 0), anim.frame);
    try testing.expectEqual(@as(f32, 0), anim.timer);
    // Subsequent positive tick still advances normally — the clamp
    // just erased the backward travel, it didn't break the clock.
    try testing.expect(anim.advance(1.0 / 6.0));
    try testing.expectEqual(@as(u8, 1), anim.frame);
}

test "SpriteAnimation: sub-zero timer from FP residual does not panic" {
    // The other path into the same bug: a prior `timer -= steps *
    // frame_duration` can land marginally below zero because of FP
    // rounding. The next `advance` would then see a negative timer
    // and trap on the cast. Simulate by poking the timer directly
    // to a tiny negative value, then calling advance with small dt.
    var anim = SpriteAnimation{
        .frames = &pipe_frames,
        .fps = 6,
        .mode = .loop,
    };
    anim.timer = -1e-7;
    // No panic, no frame change, timer clamped.
    try testing.expect(!anim.advance(0));
    try testing.expectEqual(@as(f32, 0), anim.timer);
}
