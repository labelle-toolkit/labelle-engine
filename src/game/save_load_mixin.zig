//! Save/Load mixin — generic game state serialization.
//!
//! Provides saveGameState/loadGameState methods on the Game struct.
//! Component save behavior is declared via Saveable(...) in labelle-core.
//! No game-specific code — works with any component registry.
//!
//! Thin composition barrel. The implementation is split by direction
//! (behaviour-preserving, pure extraction):
//!   * `save_load/save.zig`   — `saveGameState` (the writer).
//!   * `save_load/load.zig`   — `loadGameState` + its Phase 1a/1b/1c →
//!     Phase 2 sequence (kept together) + the post-load render gate.
//!   * `save_load/common.zig` — helpers + `SAVE_VERSION` shared by both.
//! Each is a `Mixin(Game)` instantiated here against the same `Game`; the
//! public surface (5 fns) is re-exported unchanged so `game.zig`'s aliases
//! (`SaveLoadMixin.saveGameState`, …) resolve exactly as before.

const save = @import("save_load/save.zig");
const load = @import("save_load/load.zig");

pub fn Mixin(comptime Game: type) type {
    const SaveMixin = save.Mixin(Game);
    const LoadMixin = load.Mixin(Game);

    return struct {
        pub const saveGameState = SaveMixin.saveGameState;
        pub const loadGameState = LoadMixin.loadGameState;
        pub const armPostLoadRenderGate = LoadMixin.armPostLoadRenderGate;
        pub const updatePostLoadRenderGate = LoadMixin.updatePostLoadRenderGate;
        pub const releaseLoadAcquired = LoadMixin.releaseLoadAcquired;
    };
}
