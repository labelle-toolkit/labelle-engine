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

// ── State-scoped script execution tests ─────────────────────────────

const StateScopedScripts = struct {
    pub const global_script = struct {
        // No game_states — runs in every state.
        pub fn tick(game: anytype, _: f32) void {
            game.tick_log[0] = true;
        }
    };
    pub const menu_script = struct {
        pub const game_states = .{ "menu", "settings" };
        pub fn tick(game: anytype, _: f32) void {
            game.tick_log[1] = true;
        }
    };
    pub const playing_script = struct {
        pub const game_states = .{"playing"};
        pub fn tick(game: anytype, _: f32) void {
            game.tick_log[2] = true;
        }
    };
};

const StateRunner = ScriptRunner(StateScopedScripts, struct {}, struct {});

fn StateGame(comptime state: []const u8) type {
    return struct {
        tick_log: *[3]bool,

        pub fn getState(_: *const @This()) []const u8 {
            return state;
        }
    };
}

test "state-scoped: only global and matching scripts run" {
    var tick_log = [3]bool{ false, false, false };
    const Game = StateGame("menu");
    var game = Game{ .tick_log = &tick_log };
    var runner = StateRunner.init(std.testing.allocator, &{});

    runner.tick(&game, 0.016);

    // global_script runs (no game_states)
    try std.testing.expect(tick_log[0]);
    // menu_script runs (game_states contains "menu")
    try std.testing.expect(tick_log[1]);
    // playing_script does NOT run (game_states is "playing" only)
    try std.testing.expect(!tick_log[2]);
}

test "state-scoped: different state activates different scripts" {
    var tick_log = [3]bool{ false, false, false };
    const Game = StateGame("playing");
    var game = Game{ .tick_log = &tick_log };
    var runner = StateRunner.init(std.testing.allocator, &{});

    runner.tick(&game, 0.016);

    try std.testing.expect(tick_log[0]); // global always runs
    try std.testing.expect(!tick_log[1]); // menu_script skipped
    try std.testing.expect(tick_log[2]); // playing_script runs
}

test "state-scoped: scripts run in all states when game has no getState" {
    var tick_log = [3]bool{ false, false, false };
    const LegacyGame = struct { tick_log: *[3]bool };
    var game = LegacyGame{ .tick_log = &tick_log };
    var runner = StateRunner.init(std.testing.allocator, &{});

    runner.tick(&game, 0.016);

    // Without getState, all scripts run regardless of game_states.
    try std.testing.expect(tick_log[0]);
    try std.testing.expect(tick_log[1]);
    try std.testing.expect(tick_log[2]);
}
