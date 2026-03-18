/// GameLog — elapsed-time-aware logging for the engine.
///
/// Provides two usage patterns:
///   1. Through the game object:  game.log.info("msg", .{})
///   2. Standalone scoped logger: const log = Log.scoped("movement");
///                                log.info(&game.log, "vel: {d}", .{v})
///
/// Log level filtering is comptime — calls below min_level generate zero code.
/// Default: Debug=all, ReleaseSafe=info+, ReleaseFast/Small=warn+.
const core = @import("labelle-core");
const LogLevel = core.LogLevel;

/// Game-aware logger parameterized by a comptime LogSink backend and minimum log level.
pub fn GameLog(comptime LogSink: type, comptime min_level: LogLevel) type {
    const Sink = core.LogSinkInterface(LogSink);

    return struct {
        const Self = @This();

        elapsed_s: f64 = 0,

        /// Called by game.tick() each frame to accumulate elapsed time.
        pub fn update(self: *Self, dt: f32) void {
            self.elapsed_s += @as(f64, dt);
        }

        /// Reset elapsed time (e.g., on scene change).
        pub fn reset(self: *Self) void {
            self.elapsed_s = 0;
        }

        // ── Direct logging (default scope) ──────────────────────────

        pub fn debug(self: *const Self, comptime fmt: []const u8, args: anytype) void {
            if (comptime @intFromEnum(LogLevel.debug) >= @intFromEnum(min_level)) {
                Sink.write(.debug, "", self.elapsed_s, fmt, args);
            }
        }

        pub fn info(self: *const Self, comptime fmt: []const u8, args: anytype) void {
            if (comptime @intFromEnum(LogLevel.info) >= @intFromEnum(min_level)) {
                Sink.write(.info, "", self.elapsed_s, fmt, args);
            }
        }

        pub fn warn(self: *const Self, comptime fmt: []const u8, args: anytype) void {
            if (comptime @intFromEnum(LogLevel.warn) >= @intFromEnum(min_level)) {
                Sink.write(.warn, "", self.elapsed_s, fmt, args);
            }
        }

        pub fn err(self: *const Self, comptime fmt: []const u8, args: anytype) void {
            if (comptime @intFromEnum(LogLevel.err) >= @intFromEnum(min_level)) {
                Sink.write(.err, "", self.elapsed_s, fmt, args);
            }
        }

        // ── Scoped logging ──────────────────────────────────────────

        /// Returns a scoped logger. Declare at module level for zero-cost scope tagging:
        ///   const log = Log.scoped("movement");
        pub fn scoped(comptime scope: []const u8) ScopedLog(scope) {
            return .{};
        }

        pub fn ScopedLog(comptime scope: []const u8) type {
            return struct {
                pub fn debug(_: @This(), log: *const Self, comptime fmt: []const u8, args: anytype) void {
                    if (comptime @intFromEnum(LogLevel.debug) >= @intFromEnum(min_level)) {
                        Sink.write(.debug, scope, log.elapsed_s, fmt, args);
                    }
                }

                pub fn info(_: @This(), log: *const Self, comptime fmt: []const u8, args: anytype) void {
                    if (comptime @intFromEnum(LogLevel.info) >= @intFromEnum(min_level)) {
                        Sink.write(.info, scope, log.elapsed_s, fmt, args);
                    }
                }

                pub fn warn(_: @This(), log: *const Self, comptime fmt: []const u8, args: anytype) void {
                    if (comptime @intFromEnum(LogLevel.warn) >= @intFromEnum(min_level)) {
                        Sink.write(.warn, scope, log.elapsed_s, fmt, args);
                    }
                }

                pub fn err(_: @This(), log: *const Self, comptime fmt: []const u8, args: anytype) void {
                    if (comptime @intFromEnum(LogLevel.err) >= @intFromEnum(min_level)) {
                        Sink.write(.err, scope, log.elapsed_s, fmt, args);
                    }
                }
            };
        }
    };
}
