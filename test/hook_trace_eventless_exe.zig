//! Tracing must not break a game that declares NO events (#858 review).
//!
//! `GameConfig` with `GameEvents == void` gives a `void` event buffer. The
//! traced enqueue path appended to it unconditionally, so turning tracing
//! on stopped such a game COMPILING — "no field or member function append
//! in void". `tryEmit` guarded on `has_events` before delegating; `emit`'s
//! traced branch did not.
//!
//! This harness is the regression: it is an eventless game with tracing
//! ENABLED. Its value is mostly that it BUILDS at all — the bug was a
//! compile error, so a test that merely runs is the assertion. The runtime
//! checks below additionally pin the documented eventless contract:
//! `emit` no-ops and `tryEmit` returns SUCCESS ("nothing was dropped",
//! not "an event is pending").
//!
//! Tracing cannot be enabled from a `zig test` binary — the compilation
//! root there is Zig's test runner — so this is an executable, wired into
//! `zig build test` like its siblings.

const std = @import("std");
const engine = @import("engine");
const core = engine.core;

pub const labelle_hook_trace: engine.HookTraceOptions = .{ .ring_capacity = 8 };

const Entity = u32;
const EmptyComponents = struct {};

/// A receiver with no handlers at all — an eventless game still assembles
/// a dispatcher, which is part of what must keep compiling.
const NoHooks = struct {};
const AllHooks = engine.MergeHooks(engine.HookPayload(Entity), .{*NoHooks});

const AssembledGame = engine.GameConfig(
    core.StubRender(Entity),
    core.MockEcsBackend(u32),
    engine.StubInput,
    engine.StubAudio,
    engine.StubVideo,
    engine.StubGui,
    *AllHooks,
    core.StubLogSink,
    EmptyComponents,
    &.{},
    void, // ← no declared events
);

pub const Game = AssembledGame;

var failures: usize = 0;
fn expect(ok: bool, what: []const u8) void {
    if (ok) return;
    failures += 1;
    std.debug.print("hook_trace_eventless_exe: FAIL {s}\n", .{what});
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var no_hooks = NoHooks{};
    var hooks = AllHooks{ .receivers = .{&no_hooks} };
    var game = Game.init(allocator);
    defer game.deinit();
    game.setHooks(&hooks);

    // Lifecycle hooks (`game_init` etc.) are traced during init, so the
    // absolute counters are non-zero here. Measure the DELTA across the
    // emits — that is the claim being made.
    const seq_before = game.hook_tracer.seq;
    const dropped_before = game.hook_tracer.dropped;

    // The whole point: these two lines did not compile with tracing on.
    game.emit({});
    game.tryEmit({}) catch {
        expect(false, "tryEmit on an eventless game must return success");
    };

    // Contract: nothing queued, nothing dropped, nothing traced.
    expect(game.hook_tracer.seq == seq_before, "an eventless emit records no trace entry");
    expect(game.hook_tracer.dropped == dropped_before, "an eventless emit drops nothing");

    if (failures == 0) {
        std.debug.print("hook_trace_eventless_exe: ok (eventless + tracing builds and no-ops)\n", .{});
    } else {
        std.process.exit(1);
    }
}
