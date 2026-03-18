const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const core = @import("labelle-core");

const GameLog = engine.GameLog;

// A test sink that captures the last log call for assertions.
const CapturingSink = struct {
    var last_level: ?core.LogLevel = null;
    var last_scope: []const u8 = "";
    var last_elapsed: f64 = 0;
    var call_count: usize = 0;

    pub fn write(
        level: core.LogLevel,
        comptime scope: []const u8,
        elapsed_s: f64,
        comptime _: []const u8,
        _: anytype,
    ) void {
        last_level = level;
        last_scope = scope;
        last_elapsed = elapsed_s;
        call_count += 1;
    }

    fn reset() void {
        last_level = null;
        last_scope = "";
        last_elapsed = 0;
        call_count = 0;
    }
};

const Log = GameLog(CapturingSink);

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

test "GameLog: direct log passes elapsed time and level to sink" {
    var log = Log{};
    CapturingSink.reset();

    log.update(2.5);
    log.info("player count: {d}", .{4});

    try testing.expectEqual(core.LogLevel.info, CapturingSink.last_level.?);
    try testing.expectEqualStrings("", CapturingSink.last_scope);
    try testing.expectApproxEqAbs(@as(f64, 2.5), CapturingSink.last_elapsed, 1e-6);
    try testing.expectEqual(@as(usize, 1), CapturingSink.call_count);
}

test "GameLog: direct log levels map correctly" {
    var log = Log{};
    CapturingSink.reset();

    log.debug("d", .{});
    try testing.expectEqual(core.LogLevel.debug, CapturingSink.last_level.?);

    log.warn("w", .{});
    try testing.expectEqual(core.LogLevel.warn, CapturingSink.last_level.?);

    log.err("e", .{});
    try testing.expectEqual(core.LogLevel.err, CapturingSink.last_level.?);

    try testing.expectEqual(@as(usize, 3), CapturingSink.call_count);
}

test "GameLog: scoped log passes scope and elapsed time" {
    var log = Log{};
    CapturingSink.reset();

    log.update(1.0);
    const scoped = Log.scoped("movement");
    scoped.info(&log, "velocity: {d}", .{5.0});

    try testing.expectEqual(core.LogLevel.info, CapturingSink.last_level.?);
    try testing.expectEqualStrings("movement", CapturingSink.last_scope);
    try testing.expectApproxEqAbs(@as(f64, 1.0), CapturingSink.last_elapsed, 1e-6);
}
