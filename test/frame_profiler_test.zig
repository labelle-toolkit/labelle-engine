//! Tests for the FPS / frame-time tracker feeding the debug inspector
//! (labelle-engine#380). Covers the FrameProfiler in isolation and its
//! wiring onto `Game` (`game.fps()` / `game.frameStats()`). Fully headless
//! — no window, no graphics backend.

const std = @import("std");
const testing = std.testing;

const engine = @import("engine");
const FrameProfiler = engine.FrameProfiler;
const Game = engine.Game;

test "frame profiler: empty state reports zero FPS" {
    const fp = FrameProfiler{};
    try testing.expectEqual(@as(f32, 0), fp.fps());
    try testing.expectEqual(@as(usize, 0), fp.stats().samples);
}

test "frame profiler: steady 60 FPS frame time yields 60 FPS" {
    var fp = FrameProfiler{};
    const dt: f32 = 1.0 / 60.0;
    var i: usize = 0;
    while (i < 10) : (i += 1) fp.record(dt);
    // Constant dt: the EMA seeds to dt on the first sample and never
    // diverges, so FPS is exactly 60.
    try testing.expectApproxEqAbs(@as(f32, 60.0), fp.fps(), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 1000.0 / 60.0), fp.frameTimeMs(), 0.01);
}

test "frame profiler: steady 30 FPS frame time yields 30 FPS" {
    var fp = FrameProfiler{};
    const dt: f32 = 1.0 / 30.0;
    var i: usize = 0;
    while (i < 5) : (i += 1) fp.record(dt);
    try testing.expectApproxEqAbs(@as(f32, 30.0), fp.fps(), 0.01);
}

test "frame profiler: smoothing converges toward a sustained new frame time" {
    var fp = FrameProfiler{};
    // Warm up at 60 FPS (16.67 ms), then a sustained drop to 20 FPS (50 ms).
    fp.record(1.0 / 60.0);
    var i: usize = 0;
    while (i < 200) : (i += 1) fp.record(1.0 / 20.0);
    // After many frames the EMA has effectively settled on the new rate.
    try testing.expectApproxEqAbs(@as(f32, 20.0), fp.fps(), 0.1);
}

test "frame profiler: rejects non-positive and non-finite samples" {
    var fp = FrameProfiler{};
    fp.record(0); // paused / zero-length frame
    fp.record(-1.0); // clock went backwards
    fp.record(std.math.nan(f32));
    fp.record(std.math.inf(f32));
    // Nothing recorded → still empty.
    try testing.expectEqual(@as(usize, 0), fp.stats().samples);
    try testing.expectEqual(@as(f32, 0), fp.fps());

    fp.record(1.0 / 60.0);
    try testing.expectEqual(@as(usize, 1), fp.stats().samples);
}

test "frame profiler: min/avg/max over the window" {
    var fp = FrameProfiler{};
    fp.record(0.010); // 10 ms
    fp.record(0.020); // 20 ms
    fp.record(0.030); // 30 ms
    const s = fp.stats();
    try testing.expectEqual(@as(usize, 3), s.samples);
    try testing.expectApproxEqAbs(@as(f32, 10.0), s.min_ms, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 20.0), s.avg_ms, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 30.0), s.max_ms, 0.001);
}

test "frame profiler: history is oldest-first in milliseconds" {
    var fp = FrameProfiler{};
    fp.record(0.001);
    fp.record(0.002);
    fp.record(0.003);
    var buf: [8]f32 = undefined;
    const hist = fp.history(&buf);
    try testing.expectEqual(@as(usize, 3), hist.len);
    try testing.expectApproxEqAbs(@as(f32, 1.0), hist[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 2.0), hist[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 3.0), hist[2], 0.001);
}

test "frame profiler: history keeps the newest N when dst is smaller" {
    var fp = FrameProfiler{};
    fp.record(0.001);
    fp.record(0.002);
    fp.record(0.003);
    var buf: [2]f32 = undefined;
    const hist = fp.history(&buf);
    try testing.expectEqual(@as(usize, 2), hist.len);
    // Newest two: 2 ms then 3 ms.
    try testing.expectApproxEqAbs(@as(f32, 2.0), hist[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 3.0), hist[1], 0.001);
}

test "frame profiler: ring wraps and retains only window_size samples" {
    var fp = FrameProfiler{};
    var i: usize = 0;
    while (i < FrameProfiler.window_size + 50) : (i += 1) fp.record(0.016);
    try testing.expectEqual(FrameProfiler.window_size, fp.stats().samples);
}

test "frame profiler: reset clears samples but keeps smoothing" {
    var fp = FrameProfiler{ .smoothing = 0.25 };
    fp.record(0.02);
    fp.reset();
    try testing.expectEqual(@as(usize, 0), fp.stats().samples);
    try testing.expectEqual(@as(f32, 0.25), fp.smoothing);
}

test "game: fps accessor reflects recorded frame times" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    // Before any frame the readout is zero.
    try testing.expectEqual(@as(f32, 0), game.fps());

    game.frame_profiler.record(1.0 / 60.0);
    try testing.expectApproxEqAbs(@as(f32, 60.0), game.fps(), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 1000.0 / 60.0), game.frameTimeMs(), 0.01);
    try testing.expectEqual(@as(usize, 1), game.frameStats().samples);
}
