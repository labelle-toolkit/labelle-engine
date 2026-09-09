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
            // Engine `Events` dual-emit (#578) — the on-disk
            // `engine.state_changed` event fires on the post-transition
            // edge so flow listeners observe `game_state == new_state`.
            self.emitEngineEvent("engine__state_changed", .{ .old_state = old_state, .new_state = new_state });
        }

        /// Set the game state from a RUNTIME-sourced name whose backing
        /// storage may not outlive the game — loader parse arenas
        /// (RFC #596 `meta.initial_state`) and the studio editor's wasm
        /// buffers (`editor_api.editor_set_state`) both hand in slices
        /// that are freed right after the call, while `setState` stores
        /// its argument BY REFERENCE into `game.game_state`.
        ///
        /// Dupes onto the game allocator and stashes the owned backing
        /// on `game.owned_initial_state` (freed on `deinit`, replaced —
        /// with the previous slice freed — on every call). Extracted
        /// from the scene loader's `applyFileMetaDirectives`, which
        /// accumulated three UAF fixes (PR #599) this ordering encodes:
        ///
        ///   1. Dupe onto the game allocator — `new_owned`.
        ///   2. Swap `owned_initial_state` to the fresh dupe BEFORE
        ///      `setState`, so the field is consistent even if
        ///      `setState` early-returns.
        ///   3. `setState(new_owned)`. Its `eql` probe reads
        ///      `game.game_state`, which still aliases the prior owned
        ///      slot (still live at this point) or a default literal —
        ///      safe either way.
        ///   4. If `setState` short-circuited (state name unchanged),
        ///      `game.game_state` still aliases the about-to-be-freed
        ///      previous owned slot. Re-point to `new_owned` — but ONLY
        ///      when `game_state` is actually pointing at that slot. A
        ///      broad `ptr != new_owned` check over-reaches (#600): a
        ///      `state_after_change` hook fired by the inner `setState`
        ///      may legitimately call `setState`/`setStateOwned` again
        ///      and re-point `game_state` at a DIFFERENT state; the
        ///      guard must leave that hook-installed value untouched
        ///      rather than silently clobber it back to `new_owned`.
        ///      Gate on `game_state.ptr == old_owned.ptr` so we only
        ///      refresh the pointer when we're about to free the very
        ///      slot it aliases. No state-change hooks re-fire — the
        ///      visible value is unchanged, only the backing moves.
        ///   5. Free the previous owned slot (no-op if null).
        pub fn setStateOwned(self: *Game, state_name: []const u8) error{OutOfMemory}!void {
            const new_owned = try self.allocator.dupe(u8, state_name);
            const old_owned = self.owned_initial_state;
            self.owned_initial_state = new_owned;
            self.setState(new_owned);
            // Only reclaim the pointer if it still aliases the slot we're
            // about to free (setState short-circuited on eql). If a
            // `state_after_change` hook re-pointed `game_state` elsewhere,
            // leave its choice intact (#600).
            if (old_owned) |old_slot| {
                if (self.game_state.ptr == old_slot.ptr) {
                    self.game_state = new_owned;
                }
            }
            if (old_owned) |s| self.allocator.free(s);
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
