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

// ── syncFullscreen: the frame loop reads the real window state back ──
// (labelle-bgfx#99). The desired flag must follow a platform-side exit —
// the browser's Esc — or a checkbox bound to `isFullscreen()` lies.

test "fullscreen: sync adopts a platform-side exit" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    game.setFullscreen(true);
    try testing.expectEqual(@as(?bool, true), game.takeFullscreenRequest());
    game.syncFullscreen(true); // the backend entered fullscreen

    // The player pressed Esc in the browser: the window is windowed now.
    game.syncFullscreen(false);
    try testing.expect(!game.isFullscreen());
    // Adopting records what the window already is — nothing to apply.
    try testing.expectEqual(@as(?bool, null), game.takeFullscreenRequest());

    // So the checkbox's next click is a real request again, not a no-op.
    game.setFullscreen(true);
    try testing.expectEqual(@as(?bool, true), game.takeFullscreenRequest());
}

test "fullscreen: sync adopts a platform-side entry too" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    // e.g. the browser's own fullscreen (F11) or a permanently
    // fullscreen platform.
    game.syncFullscreen(true);
    try testing.expect(game.isFullscreen());
    try testing.expectEqual(@as(?bool, null), game.takeFullscreenRequest());
}

test "fullscreen: a pending request wins over the stale window state" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    // Requested this frame, not yet drained: the window is still windowed,
    // and adopting that would silently drop the request.
    game.setFullscreen(true);
    game.syncFullscreen(false);
    try testing.expect(game.isFullscreen());
    try testing.expectEqual(@as(?bool, true), game.takeFullscreenRequest());
}

// ── Availability: the platform's answer to "can fullscreen switch at
// all?", so a settings UI can grey the option out (labelle-bgfx#99). ──

test "fullscreen: available by default, so unreported backends keep the option" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    try testing.expect(game.isFullscreenAvailable());
}

test "fullscreen: the backend's report is what the UI reads" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    game.setFullscreenAvailable(false); // e.g. iPhone Safari
    try testing.expect(!game.isFullscreenAvailable());
    // Availability is a capability, not a request: nothing is queued.
    try testing.expectEqual(@as(?bool, null), game.takeFullscreenRequest());

    game.setFullscreenAvailable(true);
    try testing.expect(game.isFullscreenAvailable());
}
