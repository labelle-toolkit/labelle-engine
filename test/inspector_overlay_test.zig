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

test "collectScriptRows: flattens live tick + drawGui into ms rows" {
    const src = [_]profiler.ScriptRow{
        .{ .name = "physics", .tick = stat(450_000), .draw_gui = stat(120_000) },
        .{ .name = "worker_movement", .tick = stat(220_000) },
    };
    var dst: [8]profiler.OverlayRow = undefined;
    const rows = profiler.collectScriptRows(&dst, &src);

    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("physics", rows[0].name);
    try testing.expectApproxEqAbs(@as(f32, 0.45), rows[0].tick_ms, 0.001);
    try testing.expectEqualStrings("drawGui", rows[0].aux_label);
    try testing.expectApproxEqAbs(@as(f32, 0.12), rows[0].aux_ms, 0.001);
    try testing.expectEqual(profiler.Severity.good, rows[0].tick_severity);

    try testing.expectEqualStrings("worker_movement", rows[1].name);
    try testing.expectApproxEqAbs(@as(f32, 0.22), rows[1].tick_ms, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), rows[1].aux_ms, 0.001);
}

test "collectPluginRows: flattens tick + postTick with correct label" {
    const src = [_]profiler.PluginRow{
        .{ .name = "box2d", .tick = stat(1_200_000), .post_tick = stat(300_000) },
        .{ .name = "debug", .tick = stat(6_000_000) },
    };
    var dst: [8]profiler.OverlayRow = undefined;
    const rows = profiler.collectPluginRows(&dst, &src);

    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("box2d", rows[0].name);
    try testing.expectApproxEqAbs(@as(f32, 1.2), rows[0].tick_ms, 0.001);
    try testing.expectEqual(profiler.Severity.warn, rows[0].tick_severity); // 1.2ms → yellow
    try testing.expectEqualStrings("postTick", rows[0].aux_label);
    try testing.expectApproxEqAbs(@as(f32, 0.3), rows[0].aux_ms, 0.001);

    // 6ms tick → red.
    try testing.expectEqual(profiler.Severity.bad, rows[1].tick_severity);
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

test "totalMs: sums primary + secondary phase across rows" {
    const rows = [_]profiler.OverlayRow{
        .{ .name = "a", .tick_ms = 0.45, .aux_ms = 0.12 },
        .{ .name = "b", .tick_ms = 0.22, .aux_ms = 0.0 },
    };
    try testing.expectApproxEqAbs(@as(f32, 0.79), profiler.totalMs(&rows), 0.001);
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
