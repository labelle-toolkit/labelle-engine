/// State mixin — game state machine for script scoping.
///
/// States are user-defined strings declared in project.labelle.
/// Scripts run based on which state is active. The engine doesn't
/// need to know what states exist at compile time.
const std = @import("std");

/// Returns the state management mixin for a given Game type.
pub fn Mixin(comptime Game: type) type {
    return struct {
        /// Change game state immediately.
        /// Emits state_before_change and state_after_change hooks.
        /// No-op if already in the requested state.
        pub fn setState(self: *Game, new_state: []const u8) void {
            if (std.mem.eql(u8, self.game_state, new_state)) return;

            const old_state = self.game_state;
            self.emitHook(.{ .state_before_change = .{ .old_state = old_state, .new_state = new_state } });

            self.game_state = new_state;
            self.state_change_count += 1;

            self.emitHook(.{ .state_after_change = .{ .old_state = old_state, .new_state = new_state } });
        }

        /// Queue a state change for next tick. The transition happens at
        /// the start of the next tick, before scripts run.
        pub fn queueStateChange(self: *Game, new_state: []const u8) void {
            self.pending_state_change = new_state;
        }

        /// Get the current game state.
        pub fn getState(self: *const Game) []const u8 {
            return self.game_state;
        }
    };
}
