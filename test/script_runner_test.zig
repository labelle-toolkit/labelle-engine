const std = @import("std");
const engine = @import("engine");

const ScriptRunner = engine.ScriptRunner;

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

// ── Event dispatch tests ──────────────────────────────────────────────

const TestEvent = union(enum) {
    ping: struct { value: u32 },
    pong: struct { value: u32 },
};

const EventScripts = struct {
    pub const listener = struct {
        pub const State = struct {
            received: std.ArrayList(u32) = .{},
            allocator: std.mem.Allocator = undefined,

            pub fn init(allocator: std.mem.Allocator, _: anytype) @This() {
                return .{ .allocator = allocator };
            }
            pub fn deinit(self: *@This()) void {
                self.received.deinit(self.allocator);
            }
        };

        pub fn onEvent(_: anytype, state: *State, event: TestEvent) void {
            switch (event) {
                .ping => |e| state.received.append(state.allocator, e.value) catch {},
                .pong => {},
            }
        }
    };
    pub const non_listener = struct {
        // Script without onEvent — should be skipped.
        pub fn tick(_: anytype, _: f32) void {}
    };
};

const EventRunner = ScriptRunner(EventScripts, struct {}, struct {});

const EventGame = struct {
    allocator: std.mem.Allocator,
    event_buffer: std.ArrayList(TestEvent) = .{},

    fn init(allocator: std.mem.Allocator) EventGame {
        return .{ .allocator = allocator };
    }
    fn deinit(self: *EventGame) void {
        self.event_buffer.deinit(self.allocator);
    }
    pub fn emit(self: *EventGame, event: TestEvent) void {
        self.event_buffer.append(self.allocator, event) catch {};
    }
};

test "dispatchEvents: delivers buffered events to onEvent handlers" {
    var game = EventGame.init(std.testing.allocator);
    defer game.deinit();
    var runner = EventRunner.init(std.testing.allocator, &{});
    defer runner.deinit();

    // Buffer two events
    game.emit(.{ .ping = .{ .value = 42 } });
    game.emit(.{ .ping = .{ .value = 99 } });

    runner.dispatchEvents(&game);

    // Listener should have received both
    const received = runner.states.listener.received.items;
    try std.testing.expectEqual(@as(usize, 2), received.len);
    try std.testing.expectEqual(@as(u32, 42), received[0]);
    try std.testing.expectEqual(@as(u32, 99), received[1]);

    // Buffer should be cleared
    try std.testing.expectEqual(@as(usize, 0), game.event_buffer.items.len);
}

test "dispatchEvents: no-op when buffer is empty" {
    var game = EventGame.init(std.testing.allocator);
    defer game.deinit();
    var runner = EventRunner.init(std.testing.allocator, &{});
    defer runner.deinit();

    runner.dispatchEvents(&game);

    try std.testing.expectEqual(@as(usize, 0), runner.states.listener.received.items.len);
}

test "dispatchEvents: no-op when game has no event_buffer" {
    const NoEventsGame = struct { dummy: u8 = 0 };
    var game = NoEventsGame{};
    var runner = EventRunner.init(std.testing.allocator, &{});
    defer runner.deinit();

    // Should compile and not crash
    runner.dispatchEvents(&game);
}

test "dispatchEvents: events emitted during dispatch are not lost" {
    // Script that emits a new event when it receives one
    const ReemitScripts = struct {
        pub const reemitter = struct {
            pub const State = struct {
                count: usize = 0,
            };
            pub fn onEvent(game: anytype, state: *State, event: TestEvent) void {
                state.count += 1;
                switch (event) {
                    .ping => |e| {
                        if (e.value == 1) {
                            // Emit a new event during dispatch
                            game.emit(.{ .ping = .{ .value = 2 } });
                        }
                    },
                    .pong => {},
                }
            }
        };
    };
    const ReemitRunner = ScriptRunner(ReemitScripts, struct {}, struct {});

    var game = EventGame.init(std.testing.allocator);
    defer game.deinit();
    var runner = ReemitRunner.init(std.testing.allocator, &{});
    defer runner.deinit();

    game.emit(.{ .ping = .{ .value = 1 } });
    runner.dispatchEvents(&game);

    // First event was processed
    try std.testing.expectEqual(@as(usize, 1), runner.states.reemitter.count);

    // The re-emitted event should be in the buffer for next frame
    try std.testing.expectEqual(@as(usize, 1), game.event_buffer.items.len);

    // Dispatch again — second event processed
    runner.dispatchEvents(&game);
    try std.testing.expectEqual(@as(usize, 2), runner.states.reemitter.count);
    try std.testing.expectEqual(@as(usize, 0), game.event_buffer.items.len);
}
