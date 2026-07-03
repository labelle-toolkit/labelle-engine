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
