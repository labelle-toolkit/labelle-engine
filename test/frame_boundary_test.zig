/// Tests for the frame-boundary hook (RFC-I18N §4 / Open Question 1).
///
/// `Game.setFrameBoundaryFn` registers a `fn () void` fired at the very
/// top of `tick()` — before the pause gate — so it runs exactly once per
/// frame on every frame, paused ones included. It is the splice point the
/// assembler-generated `main.zig` uses to wire the generated i18n module's
/// `resetFrameArena` (the `tf()` ring buffer's "results live for the
/// current frame" contract).

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");

const game_mod = engine.game_mod;

// ── Callback counter ────────────────────────────────────────────────────
// The hook is a bare `fn () void` (matching the generated i18n module's
// `resetFrameArena` signature), so the test observes it through a
// file-scope counter rather than a captured context.

var boundary_count: usize = 0;

fn countBoundary() void {
    boundary_count += 1;
}

// ── Mock generated i18n module ──────────────────────────────────────────
// The exact shape the assembler generates: a module-owned buffer cursor
// plus a `resetFrameArena` that rewinds it. Wiring it through the hook is
// the whole integration.

const mock_i18n = struct {
    var frame_len: usize = 0;

    pub fn resetFrameArena() void {
        frame_len = 0;
    }
};

// ── Hook recorder (ordering) ────────────────────────────────────────────

const FrameStartRecorder = struct {
    /// `boundary_count` snapshot taken inside the `frame_start` hook.
    seen_at_frame_start: ?usize = null,
    game_ptr: ?*anyopaque = null,

    pub fn frame_start(self: *FrameStartRecorder, info: anytype) void {
        _ = info;
        self.seen_at_frame_start = boundary_count;
    }
};

const Game = game_mod.Game;
const HookedGame = game_mod.GameWith(*FrameStartRecorder);

// ── Tests ───────────────────────────────────────────────────────────────

test "no callback registered — tick runs and the slot stays null" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    try testing.expect(game.frame_boundary_fn == null);
    game.tick(0.016); // must not crash on the null slot
    try testing.expectEqual(@as(u64, 1), game.frame_number);
}

test "callback fires exactly once per tick" {
    boundary_count = 0;
    var game = Game.init(testing.allocator);
    defer game.deinit();

    game.setFrameBoundaryFn(countBoundary);

    game.tick(0.016);
    try testing.expectEqual(@as(usize, 1), boundary_count);
    game.tick(0.016);
    game.tick(0.016);
    try testing.expectEqual(@as(usize, 3), boundary_count);
}

test "callback fires on paused frames too" {
    // The pause gate early-returns out of `tick` before scripts run, but
    // a paused game still renders translated UI (the pause menu is the
    // i18n-heaviest screen) — the boundary must fire there as well.
    boundary_count = 0;
    var game = Game.init(testing.allocator);
    defer game.deinit();

    game.setFrameBoundaryFn(countBoundary);

    game.setPaused(true); // paused flag path (#465), time_scale stays 1.0
    game.tick(0.016);
    try testing.expectEqual(@as(usize, 1), boundary_count);

    game.setPaused(false);
    game.pause(); // time_scale == 0 path
    game.tick(0.016);
    try testing.expectEqual(@as(usize, 2), boundary_count);
}

test "callback runs before the frame_start hook" {
    // The boundary is the FIRST thing in `tick`, so by the time the
    // `frame_start` lifecycle hook fires the reset has already happened —
    // no `tf()` result produced this frame can predate it.
    boundary_count = 0;
    var recorder = FrameStartRecorder{};

    var game = HookedGame.init(testing.allocator);
    defer game.deinit();
    game.setHooks(&recorder);
    game.setFrameBoundaryFn(countBoundary);

    game.tick(0.016);

    // frame_start saw the boundary already counted for this frame.
    try testing.expectEqual(@as(usize, 1), recorder.seen_at_frame_start.?);
}

test "setFrameBoundaryFn(null) clears the slot" {
    boundary_count = 0;
    var game = Game.init(testing.allocator);
    defer game.deinit();

    game.setFrameBoundaryFn(countBoundary);
    game.tick(0.016);
    try testing.expectEqual(@as(usize, 1), boundary_count);

    game.setFrameBoundaryFn(null);
    game.tick(0.016);
    try testing.expectEqual(@as(usize, 1), boundary_count); // unchanged
}

test "generated-main wiring shape: i18n.resetFrameArena through the hook" {
    // Exactly what the assembler emits:
    //   game.setFrameBoundaryFn(i18n.resetFrameArena);
    var game = Game.init(testing.allocator);
    defer game.deinit();

    game.setFrameBoundaryFn(mock_i18n.resetFrameArena);

    mock_i18n.frame_len = 12345; // pretend tf() filled the ring last frame
    game.tick(0.016);
    try testing.expectEqual(@as(usize, 0), mock_i18n.frame_len);
}

test "preview: a paused, tick-skipped frame still fires the boundary via editor_api.frame (codex on #812)" {
    boundary_count = 0;
    var game = Game.init(testing.allocator);
    defer game.deinit();
    game.setFrameBoundaryFn(countBoundary);

    const editor_api = engine.editor_api;
    editor_api.editor_pause(1);
    defer editor_api.editor_pause(0);

    // Paused, no pending step: the generated preview loop skips g.tick()
    // but still runs editor_api.frame + g.render — the boundary must come
    // from frame() on those frames.
    try testing.expect(!editor_api.shouldTick());
    editor_api.frame(&game);
    try testing.expectEqual(@as(usize, 1), boundary_count);
    try testing.expect(!editor_api.shouldTick());
    editor_api.frame(&game);
    try testing.expectEqual(@as(usize, 2), boundary_count);

    // A stepped frame ticks: tick() fires the boundary, frame() must NOT
    // fire it again (double reset would free the frame's strings).
    editor_api.editor_step(1);
    try testing.expect(editor_api.shouldTick());
    game.tick(0.016);
    editor_api.frame(&game);
    try testing.expectEqual(@as(usize, 3), boundary_count);

    // Clear ALL editor module state, not just the pause flag: the deferred
    // editor_pause(0) discards pending steps, but `stepped_this_frame`
    // stays true until the next unpaused shouldTick() — run one here so a
    // later test in this binary starts from the module's resting state.
    editor_api.editor_pause(0);
    try testing.expect(editor_api.shouldTick());
}
