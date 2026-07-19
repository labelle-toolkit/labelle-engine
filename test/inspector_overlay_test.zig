//! Tests for the debug-inspector overlay data collection (#380): the
//! `profiler.collect*Rows` helpers that flatten the shipped per-script /
//! per-plugin `Stat` data into render-ready `OverlayRow`s, plus the
//! `Game.scriptProfileRows()` / `pluginProfileRows()` opaque-pointer
//! round-trip the debug plugin reads. Backend-agnostic and headless.

const std = @import("std");
const testing = std.testing;

const engine = @import("engine");
const profiler = engine.profiler;
const Game = engine.Game;

fn stat(ns: u64) profiler.Stat {
    return .{ .last_ns = ns };
}

test "severity: green < 1ms, yellow 1-5ms, red > 5ms" {
    try testing.expectEqual(profiler.Severity.good, profiler.severityForNs(0));
    try testing.expectEqual(profiler.Severity.good, profiler.severityForNs(999_999));
    try testing.expectEqual(profiler.Severity.warn, profiler.severityForNs(1_000_000));
    try testing.expectEqual(profiler.Severity.warn, profiler.severityForNs(4_999_999));
    try testing.expectEqual(profiler.Severity.bad, profiler.severityForNs(5_000_000));
    try testing.expectEqual(profiler.Severity.bad, profiler.severityForNs(12_000_000));
}

test "collectScriptRows: flattens live setup + tick + drawGui into ms rows" {
    const src = [_]profiler.ScriptRow{
        .{ .name = "physics", .setup = stat(2_000_000), .tick = stat(450_000), .draw_gui = stat(120_000) },
        .{ .name = "worker_movement", .tick = stat(220_000) },
    };
    var dst: [8]profiler.OverlayRow = undefined;
    const rows = profiler.collectScriptRows(&dst, &src);

    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("physics", rows[0].name);
    try testing.expectApproxEqAbs(@as(f32, 0.45), rows[0].tick_ms, 0.001);
    // New named per-phase fields carry the full breakdown.
    try testing.expectApproxEqAbs(@as(f32, 2.0), rows[0].setup_ms, 0.001);
    try testing.expectEqual(profiler.Severity.warn, rows[0].setup_severity); // 2ms → yellow
    try testing.expectApproxEqAbs(@as(f32, 0.12), rows[0].draw_gui_ms, 0.001);
    // Scripts have no postTick phase.
    try testing.expectApproxEqAbs(@as(f32, 0.0), rows[0].post_tick_ms, 0.001);
    // Back-compat secondary view still points at drawGui.
    try testing.expectEqualStrings("drawGui", rows[0].aux_label);
    try testing.expectApproxEqAbs(@as(f32, 0.12), rows[0].aux_ms, 0.001);
    try testing.expectEqual(profiler.Severity.good, rows[0].tick_severity);

    try testing.expectEqualStrings("worker_movement", rows[1].name);
    try testing.expectApproxEqAbs(@as(f32, 0.22), rows[1].tick_ms, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), rows[1].draw_gui_ms, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), rows[1].setup_ms, 0.001);
}

test "collectPluginRows: flattens setup + tick + postTick + drawGui" {
    const src = [_]profiler.PluginRow{
        .{ .name = "box2d", .tick = stat(1_200_000), .post_tick = stat(300_000) },
        .{ .name = "debug", .tick = stat(6_000_000), .draw_gui = stat(80_000), .setup = stat(500_000) },
    };
    var dst: [8]profiler.OverlayRow = undefined;
    const rows = profiler.collectPluginRows(&dst, &src);

    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("box2d", rows[0].name);
    try testing.expectApproxEqAbs(@as(f32, 1.2), rows[0].tick_ms, 0.001);
    try testing.expectEqual(profiler.Severity.warn, rows[0].tick_severity); // 1.2ms → yellow
    try testing.expectApproxEqAbs(@as(f32, 0.3), rows[0].post_tick_ms, 0.001);
    // Back-compat secondary view still points at postTick.
    try testing.expectEqualStrings("postTick", rows[0].aux_label);
    try testing.expectApproxEqAbs(@as(f32, 0.3), rows[0].aux_ms, 0.001);

    // 6ms tick → red; new setup/draw_gui phases surface through the collector.
    try testing.expectEqual(profiler.Severity.bad, rows[1].tick_severity);
    try testing.expectApproxEqAbs(@as(f32, 0.08), rows[1].draw_gui_ms, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), rows[1].setup_ms, 0.001);
}

test "collectScriptRows: respects destination bound" {
    const src = [_]profiler.ScriptRow{
        .{ .name = "a", .tick = stat(1) },
        .{ .name = "b", .tick = stat(2) },
        .{ .name = "c", .tick = stat(3) },
    };
    var dst: [2]profiler.OverlayRow = undefined;
    const rows = profiler.collectScriptRows(&dst, &src);
    try testing.expectEqual(@as(usize, 2), rows.len);
}

test "totalMs: sums recurring phases (tick+postTick+drawGui), excludes setup" {
    const rows = [_]profiler.OverlayRow{
        .{ .name = "a", .tick_ms = 0.45, .post_tick_ms = 0.1, .draw_gui_ms = 0.12, .setup_ms = 9.0 },
        .{ .name = "b", .tick_ms = 0.22, .draw_gui_ms = 0.0 },
    };
    // 0.45+0.1+0.12 + 0.22 = 0.89; the 9ms setup must NOT be counted.
    try testing.expectApproxEqAbs(@as(f32, 0.89), profiler.totalMs(&rows), 0.001);
}

test "game: scriptProfileRows/pluginProfileRows are empty when unwired" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    try testing.expectEqual(@as(usize, 0), game.scriptProfileRows().len);
    try testing.expectEqual(@as(usize, 0), game.pluginProfileRows().len);
}

test "game: profile row accessors round-trip the opaque pointer" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const scripts = [_]profiler.ScriptRow{
        .{ .name = "physics", .tick = stat(450_000) },
        .{ .name = "needs", .tick = stat(50_000) },
    };
    const plugins = [_]profiler.PluginRow{
        .{ .name = "box2d", .tick = stat(1_200_000), .post_tick = stat(300_000) },
    };

    // Mirror what the generated `main.zig` does after building the
    // ScriptRunner / SystemRegistry.
    game.script_profile_ptr = @ptrCast(&scripts);
    game.script_profile_count = scripts.len;
    game.plugin_profile_ptr = @ptrCast(&plugins);
    game.plugin_profile_count = plugins.len;

    const srows = game.scriptProfileRows();
    try testing.expectEqual(@as(usize, 2), srows.len);
    try testing.expectEqualStrings("physics", srows[0].name);
    try testing.expectEqual(@as(u64, 450_000), srows[0].tick.last_ns);

    const prows = game.pluginProfileRows();
    try testing.expectEqual(@as(usize, 1), prows.len);
    try testing.expectEqualStrings("box2d", prows[0].name);

    // End-to-end: the accessor feeds straight into the overlay collector.
    var buf: [8]profiler.OverlayRow = undefined;
    const overlay = profiler.collectScriptRows(&buf, srows);
    try testing.expectEqual(@as(usize, 2), overlay.len);
    try testing.expectApproxEqAbs(@as(f32, 0.45), overlay[0].tick_ms, 0.001);
}

test "profiler.setRecording overrides the env gate and null restores it" {
    // Whatever the env says (LABELLE_PROFILE may or may not be set in the
    // test runner), the override must win in both directions and `null`
    // must fall back to the env-derived baseline.
    const env_base = profiler.recording();

    profiler.setRecording(true);
    defer profiler.setRecording(null); // never leak the override
    try testing.expect(profiler.recording());

    profiler.setRecording(false);
    try testing.expect(!profiler.recording());

    profiler.setRecording(null);
    try testing.expectEqual(env_base, profiler.recording());
}

test "game: setProfilingCapture round-trips through profilingCaptureActive" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    game.setProfilingCapture(true);
    defer game.setProfilingCapture(null);
    try testing.expect(game.profilingCaptureActive());

    game.setProfilingCapture(false);
    try testing.expect(!game.profilingCaptureActive());
}

test "game: frameHistory exposes the frame-time ring oldest-first in ms" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    game.frame_profiler.record(0.010);
    game.frame_profiler.record(0.020);
    game.frame_profiler.record(0.030);

    var buf: [8]f32 = undefined;
    const hist = game.frameHistory(&buf);
    try testing.expectEqual(@as(usize, 3), hist.len);
    try testing.expectApproxEqAbs(@as(f32, 10.0), hist[0], 0.01);
    try testing.expectApproxEqAbs(@as(f32, 30.0), hist[2], 0.01);
}

test "profile rows carry setup and plugin drawGui phases" {
    // New phases (#380 follow-up): setup on both row kinds, drawGui on
    // plugins. Defaults must be zeroed so untimed phases render as 0.
    const s = profiler.ScriptRow{ .name = "boot_heavy", .setup = stat(2_000_000) };
    try testing.expectEqual(@as(u64, 2_000_000), s.setup.last_ns);
    try testing.expectEqual(@as(u64, 0), s.tick.last_ns);

    const p = profiler.PluginRow{ .name = "debug", .draw_gui = stat(80_000) };
    try testing.expectEqual(@as(u64, 80_000), p.draw_gui.last_ns);
    try testing.expectEqual(@as(u64, 0), p.setup.last_ns);
    try testing.expectEqual(profiler.Severity.good, profiler.severityForNs(p.draw_gui.last_ns));
}
