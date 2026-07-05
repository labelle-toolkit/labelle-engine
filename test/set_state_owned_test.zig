//! `Game.setStateOwned` — game-owned copy of RUNTIME-sourced state
//! names. Extracted from the scene loader's `applyFileMetaDirectives`
//! (PR #599's three UAF fixes) so `editor_api.editor_set_state` can
//! share the exact same ordering. These tests pin the ownership
//! contract; std.testing.allocator's leak/double-free detection is the
//! primary oracle.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");

const Game = engine.Game;
const game_mod = engine.game_mod;

// ── Re-entrant setState guard (#600) ────────────────────────────────
//
// A `state_after_change` hook that re-calls `setState` during a
// `setStateOwned` (the exact shape of loader `meta.initial_state` firing
// a game hook that transitions again) must have its chosen state
// preserved. The old `ptr != new_owned` refresh guard over-reached and
// clobbered the hook's state back to `new_owned`; the fix gates the
// refresh on `game_state` still aliasing the slot about to be freed.

const Redirector = struct {
    // Type-erased to break the comptime cycle: `TestGame` is
    // `GameWith(*Redirector)`, so a `*TestGame` field here would make
    // Redirector's layout depend on TestGame and vice-versa. The method
    // body may reference `TestGame` (lazy), the field may not.
    game: *anyopaque = undefined,
    armed: bool = false,
    redirect_to: []const u8 = "hooked",
    redirects: usize = 0,

    // One-shot: on the armed transition, redirect to another state.
    // Disarms first so the nested setState's own state_after_change
    // doesn't recurse.
    pub fn state_after_change(self: *Redirector, info: anytype) void {
        _ = info;
        if (!self.armed) return;
        self.armed = false;
        const game: *TestGame = @ptrCast(@alignCast(self.game));
        game.setState(self.redirect_to);
        self.redirects += 1;
    }
};

const TestGame = game_mod.GameWith(*Redirector);

test "setStateOwned: copies the name — caller may free its buffer immediately" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const buf = try testing.allocator.dupe(u8, "playing");
    try game.setStateOwned(buf);
    testing.allocator.free(buf);

    // The state survives the caller's free (game-owned backing) and
    // is NOT the caller's pointer.
    try testing.expectEqualStrings("playing", game.getState());
    try testing.expect(game.getState().ptr != buf.ptr);
}

test "setStateOwned: replacing the state frees the previous owned backing" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    try game.setStateOwned("menu");
    try game.setStateOwned("playing");
    try game.setStateOwned("paused");
    try testing.expectEqualStrings("paused", game.getState());
    // testing.allocator's leak check on deinit proves each replaced
    // backing was freed exactly once.
}

test "setStateOwned: same-content call re-points the backing without dangling" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    try game.setStateOwned("combat");
    const first_ptr = game.getState().ptr;

    // Same content from a DIFFERENT transient buffer: setState
    // short-circuits (no hooks re-fire, count unchanged), but the
    // backing must be re-pointed to the fresh dupe before the old one
    // is freed — reading the state afterwards must not touch freed
    // memory (PR #599 fix #2/#3).
    const count_before = game.state_change_count;
    const buf = try testing.allocator.dupe(u8, "combat");
    try game.setStateOwned(buf);
    testing.allocator.free(buf);

    try testing.expectEqualStrings("combat", game.getState());
    try testing.expect(game.getState().ptr != first_ptr);
    try testing.expectEqual(count_before, game.state_change_count);
}

test "setStateOwned: fires the same state transition as setState" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    try testing.expectEqualStrings("running", game.getState());
    const count_before = game.state_change_count;
    try game.setStateOwned("menu");
    try testing.expectEqual(count_before + 1, game.state_change_count);
}

test "setStateOwned: a re-entrant setState from a state hook is not clobbered (#600)" {
    var redir = Redirector{};

    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    redir.game = @ptrCast(&game);
    game.setHooks(&redir);

    // Seed an owned state first so `owned_initial_state` is non-null and
    // gets freed by the next call — this is the very slot the refresh
    // guard must not misattribute after the hook re-points `game_state`.
    try game.setStateOwned("loading");

    // Arm the hook, then simulate `applyFileMetaDirectives` handing a
    // transient buffer. The inner setState fires state_after_change,
    // whose handler transitions to "hooked".
    redir.armed = true;
    const buf = try testing.allocator.dupe(u8, "loaded");
    try game.setStateOwned(buf);
    testing.allocator.free(buf);

    // The hook fired and redirected exactly once.
    try testing.expectEqual(@as(usize, 1), redir.redirects);

    // With the old `ptr != new_owned` guard, setStateOwned would have
    // silently overwritten the hook's "hooked" back to "loaded". The
    // fixed guard leaves the hook-installed state intact.
    try testing.expectEqualStrings("hooked", game.getState());

    // No dangling: the previously owned "loading" backing was freed, but
    // `game_state` points at the static "hooked" literal — reading it is
    // safe, and testing.allocator's leak/double-free check is the oracle
    // for the freed owned slots.
}
