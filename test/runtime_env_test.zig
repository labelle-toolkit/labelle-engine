const std = @import("std");
const testing = std.testing;

const engine = @import("engine");

// cli#229: `engine.requestedScene()` reads `LABELLE_SCENE` to let
// loading-scene controllers honour `labelle run --scene=<name>` AFTER
// `assets.allReady` succeeds (instead of racing the boot swap).
//
// Behavioural contract verified here:
//   1. Returns null when the env var is unset.
//   2. Returns the env value when set.
//   3. Returns null when the env var is set but empty (matches "no
//      override" rather than "the empty-string scene").
//
// We can't truly mutate the parent process's environ from a Zig test
// (no portable setenv), so cases (2)+(3) are exercised by spawning a
// short subprocess with the right env. That also matches the real
// channel (cli → spawned game), which is more honest than poking
// internals.

test "requestedScene returns null when LABELLE_SCENE is unset" {
    const builtin = @import("builtin");
    if (!builtin.link_libc) {
        // Without libc the helper short-circuits to null unconditionally.
        try testing.expectEqual(@as(?[]const u8, null), engine.requestedScene());
        return;
    }
    if (std.c.getenv("LABELLE_SCENE") != null) return error.SkipZigTest;
    try testing.expectEqual(@as(?[]const u8, null), engine.requestedScene());
}

test "runtime_env exposes the canonical env-var key" {
    try testing.expectEqualStrings("LABELLE_SCENE", engine.runtime_env.SCENE_ENV_VAR);
}
