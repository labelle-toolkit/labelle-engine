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
    changes: std.ArrayListUnmanaged(bool) = .{},
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
