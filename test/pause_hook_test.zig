/// Tests for the engine-level pause flag (#465).
///
/// `Game.setPaused` / `Game.isPaused` give plugin-shipped scripts a
/// game-component-free way to gate per-frame work on pause. The
/// transition emits a `pause_changed` hook so game/system code can
/// react (audio fade, UI badge, etc.).

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");

const game_mod = engine.game_mod;

// ── Hook recorder ───────────────────────────────────────────────────────

const PauseRecorder = struct {
    changes: std.ArrayListUnmanaged(bool) = .empty,
    allocator: std.mem.Allocator,

    pub fn pause_changed(self: *PauseRecorder, info: anytype) void {
        self.changes.append(self.allocator, info.paused) catch unreachable;
    }

    pub fn deinit(self: *PauseRecorder) void {
        self.changes.deinit(self.allocator);
    }
};

const TestGame = game_mod.GameWith(*PauseRecorder);

// ── Tests ───────────────────────────────────────────────────────────────

test "isPaused defaults to false" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try testing.expect(!game.isPaused());
}

test "setPaused(true) flips the flag" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    game.setPaused(true);
    try testing.expect(game.isPaused());
}

test "setPaused emits pause_changed hook on transition" {
    var recorder = PauseRecorder{ .allocator = testing.allocator };
    defer recorder.deinit();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    game.setHooks(&recorder);

    game.setPaused(true);

    try testing.expectEqual(@as(usize, 1), recorder.changes.items.len);
    try testing.expect(recorder.changes.items[0]);
}

test "setPaused is idempotent — same value emits no second hook" {
    var recorder = PauseRecorder{ .allocator = testing.allocator };
    defer recorder.deinit();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    game.setHooks(&recorder);

    game.setPaused(true);
    game.setPaused(true);
    game.setPaused(true);

    try testing.expectEqual(@as(usize, 1), recorder.changes.items.len);
    try testing.expect(game.isPaused());
}

test "setPaused(false) after setPaused(true) emits change hook" {
    var recorder = PauseRecorder{ .allocator = testing.allocator };
    defer recorder.deinit();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    game.setHooks(&recorder);

    game.setPaused(true);
    game.setPaused(false);

    try testing.expectEqual(@as(usize, 2), recorder.changes.items.len);
    try testing.expect(recorder.changes.items[0]);
    try testing.expect(!recorder.changes.items[1]);
    try testing.expect(!game.isPaused());
}

test "setPaused(false) when already false is a no-op" {
    var recorder = PauseRecorder{ .allocator = testing.allocator };
    defer recorder.deinit();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    game.setHooks(&recorder);

    game.setPaused(false);

    try testing.expectEqual(@as(usize, 0), recorder.changes.items.len);
    try testing.expect(!game.isPaused());
}

// ── Gameplay clock (#25) ─────────────────────────────────────────────────

test "elapsedSeconds starts at zero" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    try testing.expectEqual(@as(f64, 0), game.elapsedSeconds());
}

test "elapsedSeconds accumulates time-scaled dt and freezes while paused" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    // Running at normal scale: the clock tracks dt.
    game.tick(0.5);
    try testing.expectApproxEqAbs(@as(f64, 0.5), game.elapsedSeconds(), 1e-6);
    game.tick(0.25);
    try testing.expectApproxEqAbs(@as(f64, 0.75), game.elapsedSeconds(), 1e-6);

    // Paused (time_scale == 0): scaled dt is 0, so the clock holds —
    // a Cooldown/Delay must not advance behind a pause menu.
    game.pause();
    game.tick(1.0);
    try testing.expectApproxEqAbs(@as(f64, 0.75), game.elapsedSeconds(), 1e-6);

    // Slow-mo (0.5×): the clock advances at half rate.
    game.resume_();
    game.setTimeScale(0.5);
    game.tick(1.0);
    try testing.expectApproxEqAbs(@as(f64, 1.25), game.elapsedSeconds(), 1e-6);
}

test "elapsedSeconds freezes under the paused flag even at full time_scale" {
    // The `paused` flag (#465) is independent of `time_scale` — pausing
    // through it leaves time_scale at 1.0, so the clock must gate on
    // isPaused(), not just a zero scale (bugbot/gemini #603).
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    game.tick(0.5);
    try testing.expectApproxEqAbs(@as(f64, 0.5), game.elapsedSeconds(), 1e-6);

    game.setPaused(true); // does NOT touch time_scale (stays 1.0)
    try testing.expect(game.isPaused());
    try testing.expectEqual(@as(f32, 1.0), game.getTimeScale());
    game.tick(1.0);
    try testing.expectApproxEqAbs(@as(f64, 0.5), game.elapsedSeconds(), 1e-6); // frozen

    game.setPaused(false);
    game.tick(0.25);
    try testing.expectApproxEqAbs(@as(f64, 0.75), game.elapsedSeconds(), 1e-6);
}
