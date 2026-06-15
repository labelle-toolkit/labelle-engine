//! Tests for the engine-owned fullscreen request API on `Game`:
//! `setFullscreen` / `toggleFullscreen` / `isFullscreen` /
//! `takeFullscreenRequest`.
//!
//! The engine holds only the *desired* fullscreen flag; the generated
//! `main.zig` frame loop drains `takeFullscreenRequest()` and forwards a
//! non-null result to the window backend (`window.setFullscreen` in
//! backends/{sokol,raylib,bgfx}/src/window.zig). That keeps the library
//! backend-agnostic — same split as `quit()`/`isRunning()`/`requestQuit`.
//!
//! These tests cover the flag + one-shot-drain semantics in isolation,
//! using the in-tree `Game = GameWith(void)` (MockEcsBackend + StubRender,
//! no real window).

const std = @import("std");
const testing = std.testing;

const engine = @import("engine");
const Game = engine.Game;

test "fullscreen: defaults to windowed with no pending request" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    try testing.expect(!game.isFullscreen());
    try testing.expectEqual(@as(?bool, null), game.takeFullscreenRequest());
}

test "fullscreen: setFullscreen flips state and queues a one-shot request" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    game.setFullscreen(true);
    try testing.expect(game.isFullscreen());

    // The request drains exactly once — the backend toggle must fire on
    // the change, not every frame.
    try testing.expectEqual(@as(?bool, true), game.takeFullscreenRequest());
    try testing.expectEqual(@as(?bool, null), game.takeFullscreenRequest());
}

test "fullscreen: setting the current mode is a no-op (no request queued)" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    // Already windowed → nothing to apply.
    game.setFullscreen(false);
    try testing.expectEqual(@as(?bool, null), game.takeFullscreenRequest());
}

test "fullscreen: toggle alternates and each change drains once" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    game.toggleFullscreen();
    try testing.expect(game.isFullscreen());
    try testing.expectEqual(@as(?bool, true), game.takeFullscreenRequest());

    game.toggleFullscreen();
    try testing.expect(!game.isFullscreen());
    try testing.expectEqual(@as(?bool, false), game.takeFullscreenRequest());
    try testing.expectEqual(@as(?bool, null), game.takeFullscreenRequest());
}
