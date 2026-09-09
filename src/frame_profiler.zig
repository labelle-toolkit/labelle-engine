//! FrameProfiler — the engine-side FPS / frame-time tracker for the debug
//! inspector (labelle-engine#380).
//!
//! Sibling to `scene/src/profiler.zig`: that module records per-script /
//! per-plugin *dispatch* timings (env-gated by `LABELLE_PROFILE`); this one
//! records the *whole-frame* dt every tick and derives an FPS reading for
//! the always-visible inspector header. Unlike the per-script profiler it is
//! NOT gated — the only cost is stashing one `f32` and an EMA update per
//! frame, so it can always feed the inspector without a flag.
//!
//! Backend-agnostic and allocation-free: a fixed 120-frame ring plus a
//! smoothed-dt accumulator. Nothing here touches a graphics backend, so it
//! is fully headless-testable (see `test/frame_profiler_test.zig`).

const std = @import("std");

/// Rolling frame-time tracker. Owns a fixed window of the most recent frame
/// durations (seconds) and a smoothed dt for a steady on-screen FPS number.
pub const FrameProfiler = struct {
    /// Number of frames retained for the min/avg/max window and the
    /// inspector's frame-time mini-graph (~2 s at 60 FPS).
    pub const window_size: usize = 120;

    /// EMA smoothing factor for the displayed FPS. Small enough that the
    /// headline number doesn't jitter frame-to-frame, large enough to react
    /// to a sustained drop within a few frames.
    pub const default_smoothing: f32 = 0.1;

    /// Ring of recent frame times in **seconds**. Newest write is at
    /// `(index - 1) % window_size`.
    frame_times: [window_size]f32 = [_]f32{0} ** window_size,
    /// Next write slot in the ring.
    index: usize = 0,
    /// Valid samples in the ring, saturating at `window_size`.
    count: usize = 0,
    /// Exponential moving average of frame time (seconds). 0 until the
    /// first sample so `fps()` reports 0 rather than a divide-by-zero.
    smoothed_dt: f32 = 0,
    /// EMA alpha; see `default_smoothing`.
    smoothing: f32 = default_smoothing,

    /// Record one frame's duration. `dt` is the real (unscaled) frame time
    /// in seconds. Non-positive / non-finite samples (a paused first frame,
    /// a NaN from a stalled clock) are dropped so they can't poison the
    /// average or push FPS to infinity.
    pub fn record(self: *FrameProfiler, dt: f32) void {
        // `!(dt > 0)` also rejects NaN (every comparison with NaN is false).
        if (!(dt > 0) or !std.math.isFinite(dt)) return;
        self.frame_times[self.index] = dt;
        self.index = (self.index + 1) % window_size;
        if (self.count < window_size) self.count += 1;
        self.smoothed_dt = if (self.smoothed_dt <= 0)
            dt
        else
            self.smoothed_dt + self.smoothing * (dt - self.smoothed_dt);
    }

    /// Smoothed frames-per-second. 0 before the first sample.
    pub fn fps(self: *const FrameProfiler) f32 {
        if (self.smoothed_dt <= 0) return 0;
        return 1.0 / self.smoothed_dt;
    }

    /// Smoothed frame time in milliseconds (the "16.7ms" readout).
    pub fn frameTimeMs(self: *const FrameProfiler) f32 {
        return self.smoothed_dt * 1000.0;
    }

    /// Min / avg / max frame time (ms) plus derived FPS over the window.
    pub const Stats = struct {
        min_ms: f32 = 0,
        avg_ms: f32 = 0,
        max_ms: f32 = 0,
        /// Smoothed FPS (same value as `fps()`), carried here so the
        /// inspector can pull one struct.
        fps: f32 = 0,
        /// Valid samples the stats were computed from.
        samples: usize = 0,
    };

    /// Compute min/avg/max over the retained window. Empty → all zero.
    pub fn stats(self: *const FrameProfiler) Stats {
        if (self.count == 0) return .{ .fps = self.fps() };
        var min_s: f32 = std.math.floatMax(f32);
        var max_s: f32 = 0;
        var sum_s: f32 = 0;
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const v = self.frame_times[i];
            if (v < min_s) min_s = v;
            if (v > max_s) max_s = v;
            sum_s += v;
        }
        const avg_s = sum_s / @as(f32, @floatFromInt(self.count));
        return .{
            .min_ms = min_s * 1000.0,
            .avg_ms = avg_s * 1000.0,
            .max_ms = max_s * 1000.0,
            .fps = self.fps(),
            .samples = self.count,
        };
    }

    /// Copy the frame-time history (ms) into `dst` oldest-first, newest
    /// last — the order a left-to-right mini-graph wants. Returns the
    /// filled prefix. `dst` shorter than the sample count keeps only the
    /// most recent `dst.len` frames.
    pub fn history(self: *const FrameProfiler, dst: []f32) []f32 {
        const n = @min(self.count, dst.len);
        if (n == 0) return dst[0..0];
        // Oldest retained sample sits `count` slots behind `index`.
        var src = (self.index + window_size - self.count) % window_size;
        // Skip ahead when dst can't hold the whole window (keep newest n).
        var skip = self.count - n;
        while (skip > 0) : (skip -= 1) src = (src + 1) % window_size;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            dst[i] = self.frame_times[src] * 1000.0;
            src = (src + 1) % window_size;
        }
        return dst[0..n];
    }

    /// Clear all samples (e.g. on scene change so a load stall doesn't
    /// linger in the graph).
    pub fn reset(self: *FrameProfiler) void {
        self.* = .{ .smoothing = self.smoothing };
    }
};
