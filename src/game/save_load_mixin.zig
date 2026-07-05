//! Save/Load mixin — generic game state serialization.
//!
//! Provides saveGameState/loadGameState methods on the Game struct.
//! Component save behavior is declared via Saveable(...) in labelle-core.
//! No game-specific code — works with any component registry.
//!
//! Facade over the `save_load/` sub-modules (>1000-line split, same
//! shape as the scene_loader family):
//!   - `save_load/shared.zig`      — JSON helpers, child walker, id plumbing
//!   - `save_load/writer.zig`      — `saveGameState`
//!   - `save_load/restore.zig`     — two-phase `loadGameState` + release
//!   - `save_load/render_gate.zig` — post-load render gate (#637/#638)

const writer_mod = @import("save_load/writer.zig");
const restore_mod = @import("save_load/restore.zig");
const render_gate_mod = @import("save_load/render_gate.zig");

pub fn Mixin(comptime Game: type) type {
    return struct {
        const Writer = writer_mod.Writer(Game);
        const Restore = restore_mod.Restore(Game);
        const RenderGate = render_gate_mod.RenderGate(Game);

        pub const saveGameState = Writer.saveGameState;
        pub const loadGameState = Restore.loadGameState;
        pub const releaseLoadAcquired = Restore.releaseLoadAcquired;
        pub const armPostLoadRenderGate = RenderGate.armPostLoadRenderGate;
        pub const armPostLoadRenderGateFromEntry = RenderGate.armPostLoadRenderGateFromEntry;
        pub const updatePostLoadRenderGate = RenderGate.updatePostLoadRenderGate;
    };
}
