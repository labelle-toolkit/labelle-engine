//! Silent-failure hardening on the loading→gameplay transition (#697).
//!
//! The per-frame hot-reload block in `game/loop_mixin.zig` re-invokes the
//! current scene's loader. It used to swallow a loader failure with a bare
//! `catch {}`, so a genuine loader/atlas error on that transition path
//! vanished with no log. `tick` returns `void` — there is no caller to
//! propagate to — so the fix surfaces the error through the engine log
//! (`game.log.err`) while preserving control flow.
//!
//! These tests build a Game wired to a capturing log sink, drive a
//! hot-reload with a loader that fails on demand, and assert the failure
//! reaches the log (and, as a control, that a successful reload stays
//! silent so we're catching the real failure, not incidental noise).

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");

const core = engine.core;
const game_mod = engine.game_mod;

// ── Capturing log sink ──────────────────────────────────────────────────
// Records error-level writes so a test can assert the transition surfaces
// a swallowed loader failure. `err` passes every `min_level` (all / info+ /
// warn+), so this works regardless of the build's optimize mode.
const CapturingSink = struct {
    var err_count: usize = 0;
    var last_level: ?core.LogLevel = null;

    pub fn write(
        level: core.LogLevel,
        comptime _: []const u8,
        _: f64,
        comptime _: []const u8,
        _: anytype,
    ) void {
        last_level = level;
        if (level == .err) err_count += 1;
    }

    fn reset() void {
        err_count = 0;
        last_level = null;
    }
};

const EmptyComponents = struct {
    pub fn has(comptime _: []const u8) bool {
        return false;
    }
    pub fn names() []const []const u8 {
        return &.{};
    }
};

// Game wired to the capturing sink; stubs everywhere else. Mirrors the
// `GameWith(void)` shape used elsewhere in the test suite, swapping only
// the log-sink slot so `game.log.err(...)` lands in `CapturingSink`.
const TestGame = game_mod.GameConfig(
    core.StubRender(core.MockEcsBackend(u32).Entity),
    core.MockEcsBackend(u32),
    engine.StubInput,
    engine.StubAudio,
    engine.StubVideo,
    engine.StubGui,
    void, // no hooks
    CapturingSink, // capture logs
    EmptyComponents,
    &.{}, // no gizmo categories
    void, // no game events
);

// Loader that fails only when armed. The first `setScene` runs it in
// success mode so the scene commits (`current_scene_name` set); a later
// hot-reload re-invokes it in failure mode to exercise the swallow site.
var loader_should_fail = false;

fn flakyLoader(game: *TestGame) anyerror!void {
    _ = game;
    if (loader_should_fail) return error.LoaderBoom;
}

test "hot-reload loader failure is logged, not silently swallowed (#697)" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    loader_should_fail = false;
    game.registerSceneSimple("main", flakyLoader);
    try game.setScene("main");
    try testing.expect(game.getCurrentSceneName() != null);

    // Arm the loader to fail and request a hot reload of the current scene.
    loader_should_fail = true;
    game.hot_reload_dirty = true;
    CapturingSink.reset();

    // The hot-reload block re-invokes the (now failing) loader. Before the
    // fix this vanished; now it must reach the log at error level.
    game.tick(0.016);

    try testing.expectEqual(@as(usize, 1), CapturingSink.err_count);
    try testing.expectEqual(core.LogLevel.err, CapturingSink.last_level.?);
    // The gate consumed the dirty flag exactly once.
    try testing.expect(!game.hot_reload_dirty);
}

test "successful hot-reload logs no error (#697 control)" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    loader_should_fail = false;
    game.registerSceneSimple("main", flakyLoader);
    try game.setScene("main");

    game.hot_reload_dirty = true;
    CapturingSink.reset();

    // Loader succeeds this time — the transition must stay silent, proving
    // the failure test above is catching the real loader error and not
    // incidental error logging from the tick pipeline.
    game.tick(0.016);

    try testing.expectEqual(@as(usize, 0), CapturingSink.err_count);
}
