/// GameLog — elapsed-time-aware logging for the engine.
///
/// Provides two usage patterns:
///   1. Through the game object:  game.log.info("msg", .{})
///   2. Standalone scoped logger: const log = GameLog.scoped(.movement)
///                                log.info(game, "vel: {d}", .{v})
const core = @import("labelle-core");
const LogLevel = core.LogLevel;

/// Game-aware logger parameterized by a comptime LogSink backend.
pub fn GameLog(comptime LogSink: type) type {
    const Sink = core.LogSinkInterface(LogSink);

    return struct {
        const Self = @This();

        elapsed_s: f32 = 0,

        /// Called by game.tick() each frame to accumulate elapsed time.
        pub fn update(self: *Self, dt: f32) void {
            self.elapsed_s += dt;
        }

        /// Reset elapsed time (e.g., on scene change).
        pub fn reset(self: *Self) void {
            self.elapsed_s = 0;
        }

        // ── Direct logging (default scope) ──────────────────────────

        pub fn debug(self: *const Self, comptime fmt: []const u8, args: anytype) void {
            Sink.write(.debug, "", self.elapsed_s, fmt, args);
        }

        pub fn info(self: *const Self, comptime fmt: []const u8, args: anytype) void {
            Sink.write(.info, "", self.elapsed_s, fmt, args);
        }

        pub fn warn(self: *const Self, comptime fmt: []const u8, args: anytype) void {
            Sink.write(.warn, "", self.elapsed_s, fmt, args);
        }

        pub fn err(self: *const Self, comptime fmt: []const u8, args: anytype) void {
            Sink.write(.err, "", self.elapsed_s, fmt, args);
        }

        // ── Scoped logging ──────────────────────────────────────────

        /// Returns a scoped logger. Declare at module level for zero-cost scope tagging:
        ///   const log = GameLog.scoped("movement");
        pub fn scoped(comptime scope: []const u8) ScopedLog(scope) {
            return .{};
        }

        pub fn ScopedLog(comptime scope: []const u8) type {
            return struct {
                /// Log through a game reference (gets elapsed time from game.log).
                pub fn debug(_: @This(), game: anytype, comptime fmt: []const u8, args: anytype) void {
                    Sink.write(.debug, scope, game.log.elapsed_s, fmt, args);
                }

                pub fn info(_: @This(), game: anytype, comptime fmt: []const u8, args: anytype) void {
                    Sink.write(.info, scope, game.log.elapsed_s, fmt, args);
                }

                pub fn warn(_: @This(), game: anytype, comptime fmt: []const u8, args: anytype) void {
                    Sink.write(.warn, scope, game.log.elapsed_s, fmt, args);
                }

                pub fn err(_: @This(), game: anytype, comptime fmt: []const u8, args: anytype) void {
                    Sink.write(.err, scope, game.log.elapsed_s, fmt, args);
                }
            };
        }
    };
}
