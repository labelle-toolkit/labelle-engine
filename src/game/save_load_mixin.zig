//! Save/Load mixin — generic game state serialization.
//!
//! Provides saveGameState/loadGameState methods on the Game struct.
//! Component save behavior is declared via Saveable(...) in labelle-core.
//! No game-specific code — works with any component registry.
//!
//! Thin composition barrel. The implementation is split into focused
//! modules (behaviour-preserving, pure extraction — engine#762):
//!   * `save_load/save.zig`        — `saveGameState` (the serialization walk).
//!   * `save_load/load.zig`        — `loadGameState` + its Phase 1a/1b/1c →
//!     Phase 2 sequence (kept together) — the rehydration/load seams.
//!   * `save_load/render_gate.zig` — the transient post-load render-gate
//!     machinery (`armPostLoadRenderGate`, `updatePostLoadRenderGate`,
//!     `releaseLoadAcquired`) with its own per-frame lifecycle.
//!   * `save_load/common.zig`      — helpers + `SAVE_VERSION` shared by all.
//! Each is a `Mixin(Game)` instantiated here against the same `Game`; the
//! public surface (5 fns) is re-exported unchanged so `game.zig`'s aliases
//! (`SaveLoadMixin.saveGameState`, …) resolve exactly as before.

const save = @import("save_load/save.zig");
const load = @import("save_load/load.zig");
const render_gate = @import("save_load/render_gate.zig");

pub fn Mixin(comptime Game: type) type {
    const SaveMixin = save.Mixin(Game);
    const LoadMixin = load.Mixin(Game);
    const RenderGateMixin = render_gate.Mixin(Game);

    return struct {
        pub const saveGameState = SaveMixin.saveGameState;
        pub const loadGameState = LoadMixin.loadGameState;
        pub const armPostLoadRenderGate = RenderGateMixin.armPostLoadRenderGate;
        pub const updatePostLoadRenderGate = RenderGateMixin.updatePostLoadRenderGate;
        pub const releaseLoadAcquired = RenderGateMixin.releaseLoadAcquired;
    };
}
