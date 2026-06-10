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

const Timespec = extern struct { sec: i64, nsec: i64 };
extern "c" fn clock_gettime(clk: c_int, tp: *Timespec) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// Monotonic time in nanoseconds. Desktop only — returns 0 on wasm
/// (profiling is not wired for the browser build).
pub fn nowNs() u64 {
    if (is_wasm) return 0;
    const clk: c_int = switch (builtin.os.tag) {
        .macos, .ios, .watchos, .tvos => 6, // _CLOCK_MONOTONIC
        else => 1, // CLOCK_MONOTONIC (linux et al.)
    };
    var ts: Timespec = .{ .sec = 0, .nsec = 0 };
    _ = clock_gettime(clk, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Frames between log dumps while recording.
pub const dump_interval_frames: u64 = 120;
/// Entries with a worst frame below this are omitted from the log dump.
const report_threshold_ns: u64 = 100_000; // 0.1 ms

var _recording: ?bool = null;

/// True when `LABELLE_PROFILE` is set and non-empty. The env read is
/// cached so this is a cheap branch in the per-frame hot path.
pub fn recording() bool {
    if (_recording) |v| return v;
    const v = blk: {
        if (is_wasm) break :blk false;
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
