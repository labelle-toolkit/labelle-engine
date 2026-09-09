//! Scene/prefab loader — the recursive entity-tree walker that
//! turns a parsed JSONC `Value` into ECS entities. Slice 5 of #495.
//!
//! Composes the smaller modules already extracted:
//!   - `prefab_cache.zig`     — looks up `prefab` references
//!   - `ref_resolver.zig`     — registers and patches `@ref` fields
//!   - `component_apply.zig`  — turns a component `Value` into a
//!                              real ECS component
//!   - `on_ready.zig`         — fires `onReady` / `postLoad` hooks
//!
//! The body of `SceneLoader` is itself split across focused
//! submodules under `scene_loader/` (each <1000 lines) — see #495
//! follow-up. Every submodule is parameterized by the same
//! `GameType`/`Components` plus the parent `Self` type, so the
//! mutually-recursive private functions (`loadEntityInternal`,
//! `spawnAndLinkNestedEntities`, `checkEntityTreeCycles`, …) call back
//! into one another exactly as they did when inlined. This file is the
//! thin facade that wires them together and re-exports the public
//! surface — behavior is unchanged:
//!   - `scene_loader/cycle_detect.zig`  — RFC #569 cycle gate
//!   - `scene_loader/scene_process.zig` — public entries + file/source
//!                                        ingestion + `@ref` driver
//!   - `scene_loader/entity_walker.zig` — `loadEntityInternal` /
//!                                        `loadChildEntity`
//!   - `scene_loader/nested_spawn.zig`  — component-array nested spawn
//!   - `scene_loader/prefab_spawn.zig`  — runtime `spawnPrefabImpl`
//!
//! The public entry points (`loadScene`, `loadSceneFromSource`,
//! `addEmbeddedPrefab`) live here too; the bridge file
//! (`jsonc_scene_bridge.zig`) is now a thin shell that just
//! re-exports them under the `JsoncSceneBridge(GameType, Components)`
//! signature the rest of the codebase already calls into.

const cycle_detect_mod = @import("scene_loader/cycle_detect.zig");
const scene_process_mod = @import("scene_loader/scene_process.zig");
const entity_walker_mod = @import("scene_loader/entity_walker.zig");
const nested_spawn_mod = @import("scene_loader/nested_spawn.zig");
const prefab_spawn_mod = @import("scene_loader/prefab_spawn.zig");
const prefab_refresh_mod = @import("scene_loader/prefab_refresh.zig");

pub fn SceneLoader(comptime GameType: type, comptime Components: type) type {
    return struct {
        const Self = @This();

        pub const LoadEntityError = error{ IncludeDepthExceeded, OutOfMemory, InvalidFormat, PrefabCycle };
        pub const MAX_DEPTH: usize = 16;

        // Submodule namespaces, each closed over `Self` so the
        // mutually-recursive private functions resolve one another
        // through `Self.*`.
        const Cycle = cycle_detect_mod.CycleDetect(GameType, Components, Self);
        const Scene = scene_process_mod.SceneProcess(GameType, Components, Self);
        const Walker = entity_walker_mod.EntityWalker(GameType, Components, Self);
        const Nested = nested_spawn_mod.NestedSpawn(GameType, Components, Self);
        const Prefab = prefab_spawn_mod.PrefabSpawn(GameType, Components, Self);
        const Refresh = prefab_refresh_mod.PrefabRefresh(GameType, Components);

        // ── Cycle detection (RFC #569) ─────────────────────────
        pub const checkEntityTreeCycles = Cycle.checkEntityTreeCycles;

        // ── Public entry points ────────────────────────────────
        pub const loadScene = Scene.loadScene;
        pub const loadSceneFromSource = Scene.loadSceneFromSource;
        pub const addEmbeddedPrefab = Scene.addEmbeddedPrefab;

        // ── Runtime prefab spawn ───────────────────────────────
        pub const spawnPrefabImpl = Prefab.spawnPrefabImpl;

        // ── Live-instance prefab refresh (#691) ────────────────
        pub const refreshPrefabInstancesImpl = Refresh.refreshPrefabInstancesImpl;

        // ── Entity-tree walker ─────────────────────────────────
        pub const loadEntityInternal = Walker.loadEntityInternal;
        pub const loadChildEntity = Walker.loadChildEntity;

        // ── Nested-entity spawn (component array fields) ───────
        pub const spawnAndLinkNestedEntities = Nested.spawnAndLinkNestedEntities;
    };
}
