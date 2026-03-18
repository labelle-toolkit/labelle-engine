const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const core = @import("labelle-core");

const GameLog = engine.GameLog;
const StubLogSink = core.StubLogSink;
const Log = GameLog(StubLogSink);

test "GameLog: elapsed time accumulates from dt" {
    var log = Log{};
    try testing.expectEqual(@as(f64, 0), log.elapsed_s);

    log.update(0.016);
    try testing.expectApproxEqAbs(@as(f64, 0.016), log.elapsed_s, 1e-6);

    log.update(0.016);
    try testing.expectApproxEqAbs(@as(f64, 0.032), log.elapsed_s, 1e-6);
}

test "GameLog: reset clears elapsed time" {
    var log = Log{};
    log.update(1.0);
    try testing.expectApproxEqAbs(@as(f64, 1.0), log.elapsed_s, 1e-6);

    log.reset();
    try testing.expectEqual(@as(f64, 0), log.elapsed_s);
}

test "GameLog: direct logging compiles with StubLogSink" {
    var log = Log{};
    log.update(0.5);
    log.info("test message {d}", .{42});
    log.debug("debug {s}", .{"msg"});
    log.warn("warning", .{});
    log.err("error", .{});
}

test "GameLog: scoped logging compiles with StubLogSink" {
    var log = Log{};
    log.update(1.0);
    const scoped = Log.scoped("movement");
    scoped.info(&log, "velocity: {d}", .{5.0});
    scoped.debug(&log, "debug", .{});
    scoped.warn(&log, "warn", .{});
    scoped.err(&log, "err", .{});
}
