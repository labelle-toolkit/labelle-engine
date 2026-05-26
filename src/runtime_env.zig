//! Runtime-environment hooks the labelle-cli passes through to the
//! spawned game process.
//!
//! cli#229 (labelle-cli v1.42+) writes `LABELLE_SCENE=<name>` into the
//! child env when the user runs `labelle run --scene=<name>`. Loading-
//! scene controllers read this AFTER `assets.allReady` succeeds and
//! call `setScene(requested)` then — that defers the swap until atlas
//! streaming is complete, avoiding the frame-0 race for large scenes
//! (e.g. flying-platform-labelle's `colony`, 6 atlas packs).
//!
//! Centralizing the env-var read here keeps every game's loading
//! controller off the std.posix surface and gives one place to evolve
//! the channel (env var → argv → IPC) if the cli changes its mind.

const std = @import("std");
const builtin = @import("builtin");

/// Name of the env var that carries the runtime scene override.
/// Match the cli (labelle-cli/src/cli.zig) exactly — both ends must
/// agree on the key.
pub const SCENE_ENV_VAR = "LABELLE_SCENE";

/// Null-terminated form for libc's `getenv`.
const SCENE_ENV_VAR_Z: [*:0]const u8 = SCENE_ENV_VAR;

/// Return the scene name the cli requested at launch, or null if no
/// `--scene=<name>` was passed. The returned slice borrows from the
/// process's environ block and is valid for the lifetime of the
/// program (libc's `getenv` returns a pointer into the live env).
///
/// On WASI/freestanding (no env vars), always returns null.
///
/// We reach for libc's `getenv` directly because Zig 0.16 dropped
/// `std.posix.getenv` and the engine library — unlike the cli — has no
/// process-wide Environ handle to dispatch through. Every target the
/// cli spawns links libc, so this is portable in practice for the
/// channels we ship today.
pub fn requestedScene() ?[]const u8 {
    if (builtin.os.tag == .wasi) return null;
    if (!builtin.link_libc) return null;

    const raw = std.c.getenv(SCENE_ENV_VAR_Z) orelse return null;
    const val = std.mem.span(raw);
    if (val.len == 0) return null;
    return val;
}

// Tests live in test/runtime_env_test.zig per this library's
// "src + test pair" convention (CLAUDE.md).
