//! Tests for the engine-owned vsync request API on `Game`:
//! `setVsync` / `toggleVsync` / `isVsync` / `takeVsyncRequest`.
//!
//! The engine holds only the *desired* vsync flag; the generated
//! `main.zig` frame loop drains `takeVsyncRequest()` and forwards a
//! non-null result to the window backend (`window.setVsync` in
//! backends/{sokol,bgfx}/src/window.zig). That keeps the library
//! backend-agnostic — same split as fullscreen.
//!
//! Note vsync defaults ON (every backend previously hardcoded vsync on),
//! so the no-op / default expectations are the inverse of fullscreen's.

const std = @import("std");
const testing = std.testing;

const engine = @import("engine");
const Game = engine.Game;

test "vsync: defaults to ON with no pending request" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    try testing.expect(game.isVsync());
    try testing.expectEqual(@as(?bool, null), game.takeVsyncRequest());
}

test "vsync: setVsync flips state and queues a one-shot request" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    game.setVsync(false);
    try testing.expect(!game.isVsync());

    // The request drains exactly once — the backend swap-interval change
    // must fire on the change, not every frame.
    try testing.expectEqual(@as(?bool, false), game.takeVsyncRequest());
    try testing.expectEqual(@as(?bool, null), game.takeVsyncRequest());
}

test "vsync: setting the current mode is a no-op (no request queued)" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    // Already on (default) → nothing to apply.
    game.setVsync(true);
    try testing.expectEqual(@as(?bool, null), game.takeVsyncRequest());
}

test "vsync: toggle alternates and each change drains once" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    game.toggleVsync(); // on -> off
    try testing.expect(!game.isVsync());
    try testing.expectEqual(@as(?bool, false), game.takeVsyncRequest());

    game.toggleVsync(); // off -> on
    try testing.expect(game.isVsync());
    try testing.expectEqual(@as(?bool, true), game.takeVsyncRequest());
    try testing.expectEqual(@as(?bool, null), game.takeVsyncRequest());
}
