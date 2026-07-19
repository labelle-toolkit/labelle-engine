//! Lightweight per-script / per-plugin frame profiler.
//!
//! Revives the `profile[]` / `plugin_profile[]` scaffolding that was
//! stubbed during the Zig 0.16 migration (`std.time.Timer` removal).
//! Timing uses a monotonic clock (`nowNs`). The profiler is *compiled
//! into every build* — including ReleaseFast, which is where perf
//! actually matters — but only **records** when `recording()` is true,
//! gated on the `LABELLE_PROFILE` env var. When off, the per-frame cost
//! is a single cached-bool branch.
//!
//! Two surfaces:
//!   * per-entry `Stat`s are exposed via the Game's `script_profile_ptr`
//!     / `plugin_profile_ptr` for a live debug overlay (future work);
//!   * `report()` logs a sorted ranking every `dump_interval_frames`,
//!     which works **headless** (CI / no-window perf runs) — this is the
//!     surface that makes at-scale dip-hunting a flip-a-flag operation.
//!
//! Enable: `LABELLE_PROFILE=1 <game>` (or `labelle run ... ` with the
//! profiling flag once the CLI wires it). Look for `info(profiler)` lines.

const std = @import("std");
const builtin = @import("builtin");

const is_wasm = builtin.cpu.arch == .wasm32 or builtin.os.tag == .emscripten;
const is_windows = builtin.os.tag == .windows;

const Timespec = extern struct { sec: i64, nsec: i64 };
extern "c" fn clock_gettime(clk: c_int, tp: *Timespec) c_int;

/// Monotonic time in nanoseconds. Desktop only — returns 0 on wasm
/// (profiling is not wired for the browser build).
pub fn nowNs() u64 {
    if (comptime is_wasm) return 0;
    // Windows has no `clock_gettime` to link against (MSVC/UCRT don't
    // export it), so use the QueryPerformanceCounter path via ntdll —
    // the same primitive `std.Io` uses internally.
    if (comptime is_windows) {
        const w = std.os.windows;
        var qpf: w.LARGE_INTEGER = undefined;
        var qpc: w.LARGE_INTEGER = undefined;
        _ = w.ntdll.RtlQueryPerformanceFrequency(&qpf);
        _ = w.ntdll.RtlQueryPerformanceCounter(&qpc);
        const freq: u64 = @bitCast(qpf);
        const count: u64 = @bitCast(qpc);
        if (freq == 0) return 0;
        // Split into whole-seconds + remainder to avoid overflow when
        // multiplying the raw counter by ns_per_s.
        const secs = count / freq;
        const rem = count % freq;
        return secs * std.time.ns_per_s + (rem * std.time.ns_per_s) / freq;
    }
    // POSIX with libc: use the libc `clock_gettime`. The `extern "c"`
    // symbol is only referenced on this comptime branch, so non-libc
    // targets never force an unresolved libc dependency.
    if (comptime builtin.link_libc) {
        const clk: c_int = switch (builtin.os.tag) {
            .macos, .ios, .watchos, .tvos => 6, // _CLOCK_MONOTONIC
            else => 1, // CLOCK_MONOTONIC (linux et al.)
        };
        var ts: Timespec = .{ .sec = 0, .nsec = 0 };
        _ = clock_gettime(clk, &ts);
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    }
    // No libc: on Linux the monotonic clock is reachable via the raw
    // syscall (vDSO-accelerated in std). Other no-libc POSIX targets
    // have no portable clock here, so profiling stays off (0 disables
    // recording downstream).
    if (comptime builtin.os.tag == .linux) {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    }
    return 0;
}

/// Frames between log dumps while recording.
pub const dump_interval_frames: u64 = 120;
/// Entries with a worst frame below this are omitted from the log dump.
const report_threshold_ns: u64 = 100_000; // 0.1 ms

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

var _recording: ?bool = null;

/// Runtime override of the `LABELLE_PROFILE` gate, set via
/// `setRecording`. `null` = no override (env decides). This is what the
/// debug inspector flips when its Performance section opens/closes, so
/// live per-unit capture works without relaunching with the env var.
var _override: ?bool = null;

/// Force per-unit capture on (`true`), off (`false`), or defer back to
/// the `LABELLE_PROFILE` env gate (`null`). Passing `null` on close is
/// what keeps a user's env-enabled headless dump running when the
/// inspector panel merely toggled itself away.
pub fn setRecording(on: ?bool) void {
    _override = on;
}

/// True when `LABELLE_PROFILE` is set and non-empty, unless overridden
/// by `setRecording`. The env read is cached so this is a cheap branch
/// in the per-frame hot path.
///
/// The env lookup goes through libc `getenv` when libc is linked (the
/// case for every shipped desktop build — raylib pulls in libc). Without
/// libc there is no library-accessible environ block in Zig 0.16
/// (`std.os.environ` was removed and the block is threaded through
/// `main` only), so the profiler stays off rather than forcing an
/// unresolved `getenv` symbol at link time on no-libc builds.
pub fn recording() bool {
    if (_override) |v| return v;
    if (_recording) |v| return v;
    const v = blk: {
        if (comptime is_wasm) break :blk false;
        if (comptime !builtin.link_libc) break :blk false;
        if (getenv("LABELLE_PROFILE")) |raw| break :blk std.mem.span(raw).len > 0;
        break :blk false;
    };
    _recording = v;
    return v;
}

/// Rolling timing for one entry over the current dump window. `last_ns`
/// is kept across windows for the live overlay; worst/sum/samples reset
/// each dump.
pub const Stat = struct {
    last_ns: u64 = 0,
    worst_ns: u64 = 0,
    sum_ns: u64 = 0,
    samples: u64 = 0,

    pub fn record(self: *Stat, ns: u64) void {
        self.last_ns = ns;
        if (ns > self.worst_ns) self.worst_ns = ns;
        self.sum_ns += ns;
        self.samples += 1;
    }

    pub fn avgNs(self: Stat) u64 {
        return if (self.samples == 0) 0 else self.sum_ns / self.samples;
    }

    pub fn resetWindow(self: *Stat) void {
        self.worst_ns = 0;
        self.sum_ns = 0;
        self.samples = 0;
    }
};

pub const Row = struct { name: []const u8, worst_ns: u64, avg_ns: u64 };

// ── Live inspector overlay (labelle-engine#380) ──────────────────────
//
// The per-entry `Stat`s above are logged headless by `report()`. These
// types re-shape the SAME data for an on-screen debug-inspector overlay:
// stable layouts the `ScriptRunner` / `SystemRegistry` profile arrays
// are, so `Game`'s opaque `script_profile_ptr` / `plugin_profile_ptr`
// can be cast straight back to `[]const ScriptRow` / `[]const PluginRow`.

/// One game script's live timing. Layout-shared with
/// `ScriptRunner.ProfileEntry` so the Game's opaque pointer casts cleanly.
/// `setup` is recorded once at boot (unconditionally — two clock reads
/// per script, one time) and never window-reset, so the inspector can
/// always show boot cost.
pub const ScriptRow = struct {
    name: []const u8,
    setup: Stat = .{},
    tick: Stat = .{},
    draw_gui: Stat = .{},
};

/// One plugin system's live timing. Layout-shared with
/// `SystemRegistry.PluginProfileEntry`. `setup` as in `ScriptRow`;
/// `draw_gui` covers the plugin's `Systems.drawGui` phase (e.g. the
/// debug inspector's own rendering cost shows up here).
pub const PluginRow = struct {
    name: []const u8,
    setup: Stat = .{},
    tick: Stat = .{},
    post_tick: Stat = .{},
    draw_gui: Stat = .{},
};

/// Traffic-light bucket for the inspector's color coding: green < 1 ms,
/// yellow 1–5 ms, red > 5 ms (per the issue's spec).
pub const Severity = enum { good, warn, bad };

const warn_ns: u64 = 1_000_000; // 1 ms
const bad_ns: u64 = 5_000_000; // 5 ms

pub fn severityForNs(ns: u64) Severity {
    if (ns >= bad_ns) return .bad;
    if (ns >= warn_ns) return .warn;
    return .good;
}

/// A flattened, render-ready row for the overlay: the live (`last_ns`)
/// per-frame cost of an entry's primary phase (`tick`) and secondary
/// phase (`drawGui` for scripts, `postTick` for plugins), already in ms
/// with a severity bucket for coloring. Backend-agnostic — the debug
/// plugin walks these and emits imgui/text; the shape is what makes the
/// collector headless-testable.
pub const OverlayRow = struct {
    name: []const u8,
    tick_ms: f32 = 0,
    tick_severity: Severity = .good,
    /// Secondary phase label ("drawGui" or "postTick").
    aux_label: []const u8 = "",
    aux_ms: f32 = 0,
    aux_severity: Severity = .good,
};

fn nsToMs(ns: u64) f32 {
    return @as(f32, @floatFromInt(ns)) / 1e6;
}

/// Fill `dst` from a slice of script profile rows using each entry's live
/// `last_ns`. Returns the filled prefix (bounded by `dst.len`).
pub fn collectScriptRows(dst: []OverlayRow, src: []const ScriptRow) []OverlayRow {
    const n = @min(dst.len, src.len);
    for (src[0..n], 0..) |e, i| {
        dst[i] = .{
            .name = e.name,
            .tick_ms = nsToMs(e.tick.last_ns),
            .tick_severity = severityForNs(e.tick.last_ns),
            .aux_label = "drawGui",
            .aux_ms = nsToMs(e.draw_gui.last_ns),
            .aux_severity = severityForNs(e.draw_gui.last_ns),
        };
    }
    return dst[0..n];
}

/// Fill `dst` from a slice of plugin profile rows using each entry's live
/// `last_ns`. Returns the filled prefix (bounded by `dst.len`).
pub fn collectPluginRows(dst: []OverlayRow, src: []const PluginRow) []OverlayRow {
    const n = @min(dst.len, src.len);
    for (src[0..n], 0..) |e, i| {
        dst[i] = .{
            .name = e.name,
            .tick_ms = nsToMs(e.tick.last_ns),
            .tick_severity = severityForNs(e.tick.last_ns),
            .aux_label = "postTick",
            .aux_ms = nsToMs(e.post_tick.last_ns),
            .aux_severity = severityForNs(e.post_tick.last_ns),
        };
    }
    return dst[0..n];
}

/// Sum of the primary + secondary live cost across `rows`, in ms — the
/// "Total scripts" / "Total plugins" footer line.
pub fn totalMs(rows: []const OverlayRow) f32 {
    var sum: f32 = 0;
    for (rows) |r| sum += r.tick_ms + r.aux_ms;
    return sum;
}

/// Log a ranking of `rows` (sorted worst-first) under `label`, skipping
/// entries below the threshold. `rows` is sorted in place. Emitted via
/// `std.log.scoped(.profiler)` so it surfaces on stderr headless.
pub fn report(comptime label: []const u8, rows: []Row) void {
    std.mem.sort(Row, rows, {}, struct {
        fn gt(_: void, a: Row, b: Row) bool {
            return a.worst_ns > b.worst_ns;
        }
    }.gt);
    const log = std.log.scoped(.profiler);
    for (rows) |r| {
        if (r.worst_ns < report_threshold_ns) continue;
        log.info("[" ++ label ++ "] {s}: worst={d:6.2}ms avg={d:6.2}ms", .{
            r.name,
            @as(f64, @floatFromInt(r.worst_ns)) / 1e6,
            @as(f64, @floatFromInt(r.avg_ns)) / 1e6,
        });
    }
}
