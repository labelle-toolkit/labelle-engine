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
//! ## Live instances: the bounded refresh (#691)
//!
//! After a successful swap, already-spawned instances get their
//! **`.transient`-policy components** re-applied in place through
//! `game.refresh_prefab_fn` (installed by the scene bridge next to
//! `spawn_prefab_fn` — the refresh needs the bridge's `Components`
//! registry). That is the exact component set save/load already
//! resets from prefab data on every `loadGameState`, so the refresh
//! adds no new state contract. See
//! `jsonc/scene_loader/prefab_refresh.zig` for the full scope
//! contract (declared-key diffing, child `local_path` resolution,
//! entity-ref preservation, what deliberately stays untouched).
//!
//! Full re-instantiation stays out of scope, for the reasons that
//! shaped the bounded design:
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
const prefab_cache_mod = @import("../jsonc/prefab_cache.zig");
const PrefabCache = prefab_cache_mod.PrefabCache;
const Value = @import("jsonc").Value;

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
            const result = try cache.replaceFromSource(self.log, name, source);

            // Bounded live refresh (#691): re-apply `.transient`
            // components on already-spawned instances. Only when a
            // bridge installed the hook (a pre-scene push has no
            // instances to refresh) and a previous generation existed
            // (an INSERT can't have live instances either). The swap
            // above already succeeded — the refresh is best-effort by
            // design and never fails the push.
            if (self.refresh_prefab_fn) |refresh| {
                if (result.retired) |retired| {
                    const old: Value = retired;
                    refresh(self, result.key, @ptrCast(&old));
                }
            }
        }
    };
}
