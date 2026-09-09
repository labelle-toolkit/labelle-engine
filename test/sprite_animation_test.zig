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

// ── #625 progress / duration queries ──────────────────────────────

test "SpriteAnimation: clipDuration / frameDuration from frames + fps" {
    const anim = SpriteAnimation{ .frames = &pipe_frames, .fps = 6, .mode = .loop };
    // 6 frames @ 6 fps → 1s total, 1/6s per frame.
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 6.0), anim.frameDuration(), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), anim.clipDuration(), 1e-6);
}

test "SpriteAnimation: duration folds speed in, clipDuration does not" {
    var anim = SpriteAnimation{ .frames = &pipe_frames, .fps = 6, .mode = .loop };
    // speed 1 → wall == clip.
    try testing.expectApproxEqAbs(@as(f32, 1.0), anim.duration(), 1e-6);
    // speed 2 → half the wall-clock; clip length unchanged.
    anim.speed = 2.0;
    try testing.expectApproxEqAbs(@as(f32, 0.5), anim.duration(), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), anim.clipDuration(), 1e-6);
    // paused (speed 0) → report the intrinsic length, not infinity.
    anim.speed = 0;
    try testing.expectApproxEqAbs(@as(f32, 1.0), anim.duration(), 1e-6);
}

test "SpriteAnimation: progress ramps 0 → 1 across a loop cycle" {
    var anim = SpriteAnimation{ .frames = &pipe_frames, .fps = 6, .mode = .loop };
    try testing.expectApproxEqAbs(@as(f32, 0), anim.progress(), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), anim.elapsed(), 1e-6);
    // Advance to frame 3 (halfway through 6 frames).
    _ = anim.advance(3.0 / 6.0);
    try testing.expectEqual(@as(u8, 3), anim.frame);
    try testing.expectApproxEqAbs(@as(f32, 0.5), anim.progress(), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), anim.elapsed(), 1e-6);
}

test "SpriteAnimation: progress is speed-independent (fraction, not wall-clock)" {
    // The tick pre-scales dt by speed, so from the state machine's view
    // a fast clip has simply advanced further in clip-time. Progress
    // reads the same fraction regardless of what speed produced it.
    var slow = SpriteAnimation{ .frames = &pipe_frames, .fps = 6, .mode = .loop, .speed = 0.5 };
    var fast = SpriteAnimation{ .frames = &pipe_frames, .fps = 6, .mode = .loop, .speed = 2.0 };
    _ = slow.advance(0.5);
    _ = fast.advance(0.5);
    try testing.expectApproxEqAbs(slow.progress(), fast.progress(), 1e-6);
}

test "SpriteAnimation: once clip reads progress 1.0 and isComplete once finished" {
    var anim = SpriteAnimation{ .frames = &pipe_frames, .fps = 6, .mode = .once };
    try testing.expect(!anim.isComplete());
    try testing.expect(anim.progress() < 1.0);
    _ = anim.advance(1.0); // run through all frames
    try testing.expect(anim.isComplete());
    try testing.expectEqual(@as(f32, 1.0), anim.progress());
}

test "SpriteAnimation: loop and ping_pong never isComplete" {
    var loop_anim = SpriteAnimation{ .frames = &pipe_frames, .fps = 6, .mode = .loop };
    var pp_anim = SpriteAnimation{ .frames = &pipe_frames, .fps = 6, .mode = .ping_pong };
    _ = loop_anim.advance(100.0);
    _ = pp_anim.advance(100.0);
    try testing.expect(!loop_anim.isComplete());
    try testing.expect(!pp_anim.isComplete());
}

test "SpriteAnimation: degenerate clip queries are zero, not NaN" {
    const empty: []const []const u8 = &.{};
    const anim = SpriteAnimation{ .frames = empty, .fps = 6, .mode = .loop };
    try testing.expectEqual(@as(f32, 0), anim.clipDuration());
    try testing.expectEqual(@as(f32, 0), anim.duration());
    try testing.expectEqual(@as(f32, 0), anim.progress());
    // Zero fps → zero frame duration (no divide-by-zero).
    const zfps = SpriteAnimation{ .frames = &pipe_frames, .fps = 0, .mode = .loop };
    try testing.expectEqual(@as(f32, 0), zfps.frameDuration());
    try testing.expectEqual(@as(f32, 0), zfps.progress());
}

// ── #625 per-frame + lifecycle events via advanceEvents ────────────

const PendingBuf = engine.AnimPendingBuf;
const Kind = engine.AnimEventKind;

fn countKind(buf: *const PendingBuf, kind: Kind) usize {
    var c: usize = 0;
    for (buf.slice()) |e| {
        if (e.kind == kind) c += 1;
    }
    return c;
}

test "SpriteAnimation: advanceEvents fires a marker when landing on an event frame" {
    const marked = [_]u16{2};
    var anim = SpriteAnimation{
        .frames = &pipe_frames,
        .fps = 6,
        .mode = .loop,
        .event_frames = &marked,
    };
    var buf = PendingBuf{};
    // Land exactly on frame 2.
    _ = anim.advanceEvents(2.0 / 6.0, &buf);
    try testing.expectEqual(@as(u8, 2), anim.frame);
    try testing.expectEqual(@as(usize, 1), countKind(&buf, .marker));
    try testing.expectEqual(@as(u8, 2), buf.slice()[0].frame);
}

test "SpriteAnimation: unmarked frames fire no marker" {
    var anim = SpriteAnimation{ .frames = &pipe_frames, .fps = 6, .mode = .loop };
    var buf = PendingBuf{};
    _ = anim.advanceEvents(2.0 / 6.0, &buf);
    try testing.expectEqual(@as(usize, 0), countKind(&buf, .marker));
}

test "SpriteAnimation: once clip fires clip_end exactly once" {
    var anim = SpriteAnimation{ .frames = &pipe_frames, .fps = 6, .mode = .once };
    var buf = PendingBuf{};
    _ = anim.advanceEvents(1.0, &buf); // through all frames
    try testing.expectEqual(@as(usize, 1), countKind(&buf, .clip_end));
    // No re-fire on further advances.
    var buf2 = PendingBuf{};
    _ = anim.advanceEvents(10.0, &buf2);
    try testing.expectEqual(@as(usize, 0), countKind(&buf2, .clip_end));
}

test "SpriteAnimation: loop wrap fires loop_end with rising repetition" {
    var anim = SpriteAnimation{ .frames = &pipe_frames, .fps = 6, .mode = .loop };
    var buf = PendingBuf{};
    // 1s @ 6 fps over 6 frames → one full wrap back to frame 0.
    _ = anim.advanceEvents(1.0, &buf);
    try testing.expectEqual(@as(u8, 0), anim.frame);
    try testing.expectEqual(@as(usize, 1), countKind(&buf, .loop_end));
    try testing.expectEqual(@as(u16, 1), anim.repetition);
    // Two more full wraps → repetition climbs, one loop_end each.
    var buf2 = PendingBuf{};
    _ = anim.advanceEvents(2.0, &buf2);
    try testing.expectEqual(@as(usize, 2), countKind(&buf2, .loop_end));
    try testing.expectEqual(@as(u16, 3), anim.repetition);
}

test "SpriteAnimation: a full-period wrap back to the same frame fires no marker" {
    // The landed-on marker gate requires a NET frame change, so a dt of
    // exactly one full period (returns to the same index) intentionally
    // doesn't re-fire that frame's marker — only the loop_end fires. A
    // crossing-accurate design (deferred #625 follow-up) would catch it.
    const marked = [_]u16{0};
    var anim = SpriteAnimation{
        .frames = &pipe_frames,
        .fps = 6,
        .mode = .loop,
        .event_frames = &marked,
    };
    var buf = PendingBuf{};
    _ = anim.advanceEvents(1.0, &buf); // wraps exactly back to frame 0
    try testing.expectEqual(@as(u8, 0), anim.frame);
    try testing.expectEqual(@as(usize, 0), countKind(&buf, .marker));
    try testing.expectEqual(@as(usize, 1), countKind(&buf, .loop_end));
}

test "SpriteAnimation: advanceEventsMasked queues only the selected kinds" {
    // #718 codex P2 #2: a project listening to only anim_frame must not
    // have its buffer filled with loop_end events. Mask loop_end/clip_end
    // OFF; a wrapping tick that lands on a marked frame yields ONLY the
    // marker — the wanted event isn't crowded out.
    const marked = [_]u16{2};
    var anim = SpriteAnimation{
        .frames = &pipe_frames,
        .fps = 6,
        .mode = .loop,
        .event_frames = &marked,
    };
    var buf = PendingBuf{};
    // From frame 0: 8 steps → one wrap, lands on frame 2 (marked).
    _ = anim.advanceEventsMasked(8.0 / 6.0, &buf, .{ .frame = true, .clip_end = false, .loop_end = false });
    try testing.expectEqual(@as(u8, 2), anim.frame);
    try testing.expectEqual(@as(usize, 1), countKind(&buf, .marker));
    try testing.expectEqual(@as(usize, 0), countKind(&buf, .loop_end));
    try testing.expectEqual(@as(usize, 1), buf.len);
    // repetition still tracked even though loop_end wasn't queued.
    try testing.expectEqual(@as(u16, 1), anim.repetition);
}

test "SpriteAnimation: a huge-dt loop tick is bounded and repetition saturates" {
    // #718 codex P2 #3: a multi-wrap dt spike (tab resume / debugger
    // pause) must be O(bounded), not O(wraps). ~100k wraps in one tick:
    // repetition is computed arithmetically (saturates at u16 max) and
    // emission is capped by the fixed buffer, not the wrap count.
    var anim = SpriteAnimation{ .frames = &pipe_frames, .fps = 6, .mode = .loop };
    var buf = PendingBuf{};
    _ = anim.advanceEvents(100000.0, &buf);
    try testing.expectEqual(@as(u16, std.math.maxInt(u16)), anim.repetition);
    // Buffer filled to capacity, not beyond — the overflow tail is dropped.
    try testing.expectEqual(@as(usize, buf.items.len), @as(usize, buf.len));
}
