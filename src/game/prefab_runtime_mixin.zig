//! Prefab-runtime mixin — hot-swap prefab definitions on a live game
//! (labelle-studio Play mode, studio issue #24; the prefab analog of
//! `game/animation_runtime_mixin.zig`).
//!
//! Prefab JSONC is consumed at `spawnPrefab` time: `spawnPrefabImpl`
//! (`jsonc/scene_loader/prefab_spawn.zig`) looks the definition up in
//! the game's `PrefabCache` on EVERY spawn. Replacing the cache entry is
//! therefore all it takes for every *future* instantiation to use the
//! new data — runtime `spawnPrefab`/`spawnFromPrefab` calls, scene loads
//! that reference the prefab (including an `editor_load_scene` reload of
//! the current scene), and save/load Phase 1 re-spawns all resolve
//! through the same registry.
//!
//! ## What this deliberately does NOT do
//!
//! Already-spawned instances keep the components they were built with.
//! Re-instantiating them in place is not a registry concern and is not
//! cleanly boundable today:
//!
//!   * destroy + respawn loses runtime component state unless the
//!     save/load Phase 2 override pass is replayed, and dangles every
//!     entity reference OTHER entities hold into the old tree —
//!     `loadGameState` only survives this because it rebuilds the whole
//!     world under one global `id_map` remap;
//!   * `PrefabInstance.overrides` is still the `""` stub (the structured
//!     overrides pipeline is an acknowledged follow-up — see
//!     `entity_mixin.tagAsPrefabInstance`), so scene-level per-instance
//!     overrides could not be re-applied;
//!   * destroy/spawn fire lifecycle hooks and engine events into a sim
//!     the editor may have paused.
//!
//! The engine-side design for a bounded live refresh (re-applying
//! `.transient`-policy components — the ones save/load already resets
//! from prefab data by contract) is tracked in its own issue; hosts can
//! see new data live today by re-spawning (or scene-reloading) affected
//! entities.
const prefab_cache_mod = @import("../jsonc/prefab_cache.zig");
const PrefabCache = prefab_cache_mod.PrefabCache;

/// Returns the prefab-runtime mixin for a given Game type.
pub fn Mixin(comptime Game: type) type {
    return struct {
        /// Parse a prefab JSONC source and install it in the prefab
        /// registry under its effective name (replace-or-insert) so all
        /// future spawns use it. On any error NOTHING changes — the
        /// previous definition stays live, so a half-saved file never
        /// corrupts a running preview. `name` and `source` are copied;
        /// the caller may free both immediately.
        ///
        /// Uses the game's attached `PrefabCache` when one exists (the
        /// normal case — the assembler registers embedded prefabs and
        /// loads a scene before any editor push); otherwise creates the
        /// persistent cache, which the next scene load then reuses via
        /// `getOrCreatePrefabCache`'s reuse contract. The existing
        /// cache's `prefab_dir` is deliberately left untouched (only
        /// scene loads may retarget the desktop disk-fallback dir).
        pub fn reloadPrefabSource(self: *Game, name: []const u8, source: []const u8) error{ OutOfMemory, InvalidFormat }!void {
            const cache: *PrefabCache = if (self.prefab_cache_ptr) |ptr|
                @ptrCast(@alignCast(ptr))
            else
                prefab_cache_mod.initPersistentCache(self, self.prefab_dir orelse "prefabs") catch
                    return error.OutOfMemory;
            try cache.replaceFromSource(self.log, name, source);
        }
    };
}
