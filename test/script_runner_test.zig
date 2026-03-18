const std = @import("std");
const engine = @import("engine");

const ScriptRunner = engine.ScriptRunner;

// Shared script modules used across tests.
const AllScripts = struct {
    pub const alpha = struct {
        pub fn tick(game: anytype, _: f32) void {
            game.tick_log[0] = true;
        }
    };
    pub const beta = struct {
        pub fn tick(game: anytype, _: f32) void {
            game.tick_log[1] = true;
        }
    };
};

const Runner = ScriptRunner(AllScripts, struct {}, struct {});

/// Mock game that returns a specific script filter list.
fn FilteredGame(comptime filter: ?[]const []const u8) type {
    return struct {
        tick_log: *[2]bool,

        pub fn getActiveScriptNames(_: *const @This()) ?[]const []const u8 {
            return filter;
        }
    };
}

test "tick only runs scripts listed in active scene" {
    var tick_log = [2]bool{ false, false };
    const Game = FilteredGame(&.{"alpha"});
    var game = Game{ .tick_log = &tick_log };
    var runner = Runner.init(std.testing.allocator, &{});

    runner.tick(&game, 0.016);

    try std.testing.expect(tick_log[0]);
    try std.testing.expect(!tick_log[1]);
}

test "tick runs all scripts when getActiveScriptNames returns null" {
    var tick_log = [2]bool{ false, false };
    const Game = FilteredGame(null);
    var game = Game{ .tick_log = &tick_log };
    var runner = Runner.init(std.testing.allocator, &{});

    runner.tick(&game, 0.016);

    try std.testing.expect(tick_log[0]);
    try std.testing.expect(tick_log[1]);
}

test "tick runs all scripts when game has no getActiveScriptNames" {
    var tick_log = [2]bool{ false, false };
    const LegacyGame = struct { tick_log: *[2]bool };
    var game = LegacyGame{ .tick_log = &tick_log };
    var runner = Runner.init(std.testing.allocator, &{});

    runner.tick(&game, 0.016);

    try std.testing.expect(tick_log[0]);
    try std.testing.expect(tick_log[1]);
}
