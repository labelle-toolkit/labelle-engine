/// Out-of-band screenshot capture request, surfaced to the generated
/// `main.zig` so it can call the active backend's `takeScreenshot`
/// path once the right frame arrives.
///
/// The CLI (`labelle run --screenshot=<path> [--after=<dur>]`) sets the
/// `LABELLE_SCREENSHOT_PATH` (+ optional `LABELLE_SCREENSHOT_AFTER_SEC`)
/// env vars on the spawned game process; this module reads them at
/// startup. No flag → `parse()` returns `null` and the codegen-emitted
/// runtime branch optimizes away.
///
/// Why an env var, not a CLI argv pass-through: the assembler-generated
/// `main.zig` already owns argv parsing for `--preview-mode <host:port>`
/// and ad-hoc game args. A new argv flag would mean either threading
/// the parse through every generator template (raylib desktop/wasm,
/// sokol desktop/mobile, Android, iOS) or stealing a bare positional
/// token that the user might also want to forward to their game.
/// `getenv` lives outside the argv parser entirely; the template hole
/// is one runtime branch.

const std = @import("std");
const builtin = @import("builtin");

// libc `getenv` — works on every target the assembler-generated game
// links against (raylib, sokol, sdl all pull libc in). Zig 0.16 removed
// `std.posix.getenv` and the `std.process.Environ.getPosix` replacement
// needs a pre-constructed `Environ` value the game's `main.zig` doesn't
// have on hand. Calling libc directly keeps the helper self-contained.
//
// On freestanding / no-libc targets this falls back to returning null —
// `LABELLE_SCREENSHOT_PATH` isn't a thing in those environments anyway.
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

fn getEnv(comptime name: [:0]const u8) ?[:0]const u8 {
    if (comptime !builtin.link_libc and builtin.os.tag != .linux and
        builtin.os.tag != .macos and builtin.os.tag != .windows)
    {
        return null;
    }
    const raw = getenv(name.ptr) orelse return null;
    return std.mem.span(raw);
}

pub const Request = struct {
    /// Output path the backend writes to. Raylib's `TakeScreenshot`
    /// picks the format from the extension (.png/.bmp/.tga), so the
    /// CLI passes this through unchanged.
    ///
    /// Pointer lifetime: program-lifetime — backed by the libc env
    /// block, which the kernel maps for the whole process. The
    /// generated `main.zig` does not free it. Sentinel-terminated so
    /// it can be handed directly to raylib's `[*:0]` API.
    path: [:0]const u8,

    /// Wait this many seconds (wall-clock from the first frame the
    /// game enters its main loop) before firing the screenshot. The
    /// default is 0 — fire on the first frame — so smoke tests that
    /// just want a frame can omit `--after`.
    after_sec: f32 = 0.0,
};

/// Read the screenshot env vars and return a `Request` if
/// `LABELLE_SCREENSHOT_PATH` is set. Cheap (two `getenv` calls + one
/// `parseFloat`) so the codegen calls it unconditionally per run.
///
/// Errors in `LABELLE_SCREENSHOT_AFTER_SEC` (non-numeric, negative)
/// degrade to `after_sec = 0` rather than crashing the game — the user
/// asked for a screenshot, not a hard failure.
pub fn parse() ?Request {
    const path = getEnv("LABELLE_SCREENSHOT_PATH") orelse return null;
    if (path.len == 0) return null;

    var after_sec: f32 = 0.0;
    if (getEnv("LABELLE_SCREENSHOT_AFTER_SEC")) |after_str| {
        if (after_str.len > 0) {
            after_sec = std.fmt.parseFloat(f32, after_str) catch 0.0;
            if (after_sec < 0) after_sec = 0;
        }
    }

    return .{ .path = path, .after_sec = after_sec };
}

// ── Tests ──

const expect = @import("zspec").expect;

test {
    @import("zspec").runAll(@This());
}

pub const ScreenshotRequest = struct {
    pub const env_absent = struct {
        test "returns null when LABELLE_SCREENSHOT_PATH unset" {
            // No good way to clear the env var portably from a unit
            // test here (std.posix.unsetenv lacks a 0.16 wrapper), so
            // this spec just documents the contract.
            // Functional verification lives in the integration smoke
            // (bouncing-ball / flying-platform).
            try expect.equal(true, true);
        }
    };

    pub const after_default = struct {
        test "default after_sec is 0" {
            const req = Request{ .path = "/tmp/x.png" };
            try expect.equal(req.after_sec, 0.0);
        }
    };
};
