# RFC: Save/Load for Prefabs

**Status:** Draft
**Author:** Alexandre
**Date:** 2026-04-23

## Problem

Today the engine's save mixin serialises **registered components**. Everything else — non-saveable render components, runtime-created overlays, prefab-defined children whose components aren't all saveable — is gone after `loadGameState`. Games are left to hand-roll re-hydration scripts, one per kind of "thing that disappeared," and the scripts are all slight variations of the same two patterns:

**Pattern A (marker + re-add render component):**
```zig
// scripts/save_load.zig::restoreSprites, and hydroponics_animation.zig,
// and every future room's decor script…
var view = game.active_world.ecs_backend.view(.{RoomDecor}, .{Sprite});
while (view.next()) |entity| {
    const decor = game.active_world.ecs_backend.getComponent(entity, RoomDecor).?;
    const desc = decorSprite(decor.kind);
    addSprite(game, entity, desc.name, .bottom_left, .world, desc.z);
}
```

**Pattern B (runtime overlay reinit):**
```zig
// condenser_animation.zig — overlays created at runtime, not in any prefab.
// needsReinit has to detect "my cached entity IDs are stale after load" by
// probing for specific component shapes + sprite frame names. Easy to get
// wrong; we just spent five rounds hardening it.
if (needsReinit(game, state)) {
    for (0..state.count) |idx| {
        if (game.active_world.ecs_backend.entityExists(state.pipe_entities[idx])) {
            game.destroyEntity(state.pipe_entities[idx]);
        }
        if (game.active_world.ecs_backend.entityExists(state.shake_entities[idx])) {
            game.destroyEntity(state.shake_entities[idx]);
        }
    }
    initOverlays(game, state);
}
```

Recent history shows the cost:

- flying-platform-labelle **#286** — PRs #283 / #285 moved each room's background onto a `Position`-offset child. `restoreSprites` only touched `Room` entities, so the decor children rendered blank after F9. Fix: new `RoomDecor` marker + switch-table re-add + prefab tags across 4 prefabs. 9 kinds now, more coming.
- labelle-engine **#467** — nested scene entities didn't fire `postLoad`, silently breaking `Workstation.postLoad`'s slot-table rebuild.
- labelle-engine **#470** — `Parent` wasn't persisted. Children of parented prefab nodes lost their parent and rendered at raw local position, drifting to scene origin.
- flying-platform-labelle **#286 (continued)** — even with Parent persistence, `condenser_animation.zig`'s overlay reinit had a latent ID-reuse bug: `entityExists` on a stale workstation ID returned true because zig-ecs reassigns low IDs on `resetEcsBackend`. Needed three rounds of narrowing `needsReinit`.

Every one of these was the game paying for something the engine should have done: **remember what was there and put it back**.

## Proposal

Add **prefab-aware** save/load. On save, record each entity's **prefab source** (path + instance overrides). On load, **two-phase restore**:

1. **Phase 1 — Structure.** Re-instantiate every prefab-sourced entity from its recorded prefab. All children, all components (including non-saveable ones like `Sprite`), come back for free.
2. **Phase 2 — State.** Apply the saved component data on top. Runtime-mutated fields (worker FSM, storage contents, needs decay, etc.) restore normally.

Entities not sourced from a prefab (raw `createEntity` + `addComponent`) continue to use the current flat save/load path unchanged.

Once adopted, the re-hydration scripts above **delete**:

- `components/room_decor.zig` — not needed; prefabs define `Sprite` on the decor child and instantiation puts it back.
- `scripts/save_load.zig::restoreSprites` — Rooms / Ships / Items / Workers all instantiate from prefabs that carry their own `Sprite`.
- `condenser_animation.zig::needsReinit` / `initOverlays` — if overlays live in a prefab (or an auto-spawned prefab hook), they come back with the workstation.
- `hydroponics_animation.zig`'s Sprite re-add block — `HydroponicsPlant` doesn't need to be saveable.
- `worker_animation.zig`'s Sprite re-add block.
- Same story for the kitchen animation and every future animation overlay.

## Goals

1. **Zero game-side re-hydration for prefab-authored structure.** If the prefab puts it there, the engine puts it back.
2. **Preserve runtime state.** Saved component values still apply on top of re-instantiation. Worker job states, storage contents, needs values, pathfinder caches — unchanged.
3. **Gradual adoption.** Games can opt in per-prefab. The flat save format stays valid; the new format is an additive entity schema.
4. **Handles prefab overrides.** Scene-level and runtime overrides to prefab-sourced entities (e.g., a specific `Position` set via `game.setPosition` post-spawn) round-trip.
5. **Handles entity-ref remapping.** Prefab re-instantiation mints new IDs. Saved `entity_refs` / `ref_arrays` remap through the load `id_map`, same as today.

## Non-goals

- **Prefab hot reload.** If the prefab file changes between save and load, the loaded world reflects the *new* prefab — with saved overrides replayed where fields still exist. Defining a semver + migration story for prefabs is out of scope here.
- **Prefab diffing at save time.** Every prefab-sourced entity records *some* overrides even if none; we don't diff against the prefab to minimise bytes. Saves get bigger by a small amount; the complexity of exact diffing isn't worth it for v1.
- **Non-prefab entity tracking.** Entities created with `createEntity` and no prefab continue to save/load as today. They don't get Phase 1; they get the current flat component-list path. This keeps the RFC small.
- **Partial prefab instantiation.** If a prefab was modified at runtime to remove a child, we still re-instantiate the full prefab on load, then the Phase 2 pass would need to destroy the removed child. Actually we handle this — see Open Questions.

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  spawnFromPrefab(path, overrides) → entity                       │
│    resolves prefab, instantiates components + children,          │
│    tags the root with PrefabInstance { path, overrides_blob }    │
│    tags each child with PrefabChild { root, local_path }         │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
   Entity now has:  PrefabInstance (saveable)  +  all component data
   Children have:   PrefabChild (saveable)     +  all component data

┌──────────────────────────────────────────────────────────────────┐
│  saveGameState                                                   │
│    For each entity:                                              │
│      if PrefabInstance: emit {"prefab": path, "overrides": {…},  │
│                                "components": {…}}                │
│      else if PrefabChild: emit {"prefab_child": {root, path},    │
│                                 "components": {…}}               │
│      else:              emit {"components": {…}}  (as today)     │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  loadGameState (two phases)                                      │
│    Phase 1 — Structure:                                          │
│      For each {"prefab": path} record:                           │
│        new_root = spawnFromPrefab(path, saved_overrides)         │
│        id_map[old_id] = new_root                                 │
│        For each child emitted by spawn, record id_map mapping    │
│          via matching "prefab_child" records (by local_path).    │
│    Phase 2 — State:                                              │
│      For every entity in save (prefab-sourced or not):           │
│        apply "components" data, remap entity refs, fire postLoad │
└──────────────────────────────────────────────────────────────────┘
```

### New built-in components

- `PrefabInstance { path: []const u8, overrides: []const u8 }` — marker on prefab-root entities. `overrides` is an opaque JSON blob (the engine produces it at spawn time and replays it on load).
- `PrefabChild { root: Entity, local_path: []const u8 }` — marker on each child entity created by the prefab. `local_path` is the dotted path within the prefab (e.g., `"children[0]"`, `"children[2].children[0]"`). Survives save/load so Phase 1 can map old child IDs to newly-spawned child IDs. In-memory `root` is the native `Entity` handle (matching `Parent`'s convention); the save format serialises it as `u64` and remaps through the load `id_map`.

Both are engine built-ins, not registered by the game. Same treatment as `Position` and (after #470) `Parent`.

### Spawn API change

Today games typically use scene jsonc → engine parses → creates entities. The jsonc path **already** knows each entity's source prefab when one is declared. Adding `PrefabInstance` / `PrefabChild` tagging happens in `src/jsonc_scene_bridge.zig::spawnAndLinkNestedEntities` and friends.

For games that spawn prefabs programmatically (runtime overlays), the engine exposes:
```zig
pub fn spawnFromPrefab(self: *Game, path: []const u8, overrides: anytype) !Entity
```

`overrides` is a comptime-known struct whose fields are component instances; the engine serialises them into the `overrides` blob and applies them at spawn time. `condenser_animation.zig` migrates to this, replacing the `createEntity + setParent + setPosition + addSprite` sequence with a single `spawnFromPrefab("condenser_pipe_overlay", .{ .Position = .{…} })`.

### Skipping runtime-mutated fields

Two existing layers already cover this and the RFC doesn't need a third:

- `Saveable(.saveable, @This(), .{ .skip = &.{"field"} })` — declared by the **component author**, applies to every instance everywhere. Use this for fields that should never be persisted (e.g., `Workstation.eis_slots`, rebuilt in `postLoad`).
- The sibling RFC on **prefab-driven animation** (`@animate`, see `RFC-PREFAB-ANIMATION.md` — pending) — a prefab-author annotation that delegates field mutation to the engine *and* implicitly tells the save layer that those fields are engine-owned, so they stay out of the overrides blob.

An earlier revision of this RFC proposed a third attribute (`@no_override`) for per-prefab field skipping. We dropped it: all the real examples turned out to be either (a) already-covered by `Saveable.skip`, or (b) animation-driven and therefore covered by the animation RFC's `@animate`. If a case appears that neither layer fits, we'll add `@no_override` then — with a concrete use case driving the design instead of a speculative one.

### Save file format v3

Additive over v2. The `entities` array grows three new per-entity shapes:

```jsonc
{ "version": 3, "entities": [
  // v2-compatible (for non-prefab entities)
  { "id": 42, "components": { "Position": {…}, "Worker": {…} } },

  // Prefab root
  { "id": 50,
    "prefab": "hydroponics",
    "overrides": "{\"components\":{\"Position\":{\"x\":156,\"y\":0}}}",
    "components": { "Room": {…}, … }
  },

  // Prefab child
  { "id": 51,
    "prefab_child": { "root": 50, "local_path": "children[0]" },
    "components": { "Position": {…}, "RoomDecor": {…} }
  }
] }
```

`version: 2` saves load unchanged (every entity hits the v2 path, nothing is spawned from a prefab). `version: 3` saves can still carry v2-shaped entities for anything `createEntity`-sourced.

### Order of operations on load

1. `resetEcsBackend` — same as today.
2. **Phase 1:** scan saved entities for `prefab` records. For each, `spawnFromPrefab(path, overrides)`. Build `id_map`:
   - `id_map[saved_root_id] = new_root_id`.
   - For every entity the spawn created (children, grandchildren), match by `(root, local_path)` against the saved `prefab_child` records and map them too.
3. **Phase 2 (existing path, slightly adapted):** for each saved entity, look up its new entity via `id_map` (creating one fresh if it's a v2-shape non-prefab entity), apply `components` data on top, remap entity refs.
4. `postLoad` fires as today (engine #467 already covers nested entities).

### Handling child deletions

If the game destroyed a prefab-spawned child at runtime, save-time won't emit a `prefab_child` record for it. Phase 1 still re-instantiates the full prefab. Phase 2 sweeps: any child created in Phase 1 whose `(root, local_path)` didn't appear in the save is **destroyed** before Phase 2 applies component data. Clean.

## Migration of existing pain points

Each of these becomes a deletion in its own PR once the infra lands.

### RoomDecor (flying-platform-labelle #286)
- **Today:** `components/room_decor.zig` + tag in 4 prefab jsonc files + switch table in `save_load.zig`.
- **After:** Delete the component, delete the switch table, delete the `RoomDecor` tags. Prefabs already declare `Sprite` on the decor children — instantiation puts them back.

### HydroponicsPlant
- **Today:** `.saveable` marker + plant animation script has a "walk markers missing Sprite, re-add" block.
- **After:** Delete the `.saveable` policy; mark as `.transient`. The plant overlay child prefab re-instantiates with its Sprite at Phase 1; the next tick sets the correct level-driven sprite. The sprite-swap-per-level goes away once the prefab animation RFC lands (declarative `@sprite_by_field` or similar); until then it stays as a short tick-driven script.

### condenser_animation / kitchen_animation overlays
- **Today:** Runtime `createEntity + setParent + addSprite` in `initOverlays`; `needsReinit` dance to detect stale state after save/load.
- **After:** Move overlay creation into a `condenser_overlay.jsonc` prefab. At scene-init the animation script calls `spawnFromPrefab("condenser_overlay", .{…})` per workstation. On save/load Phase 1 brings them back. `needsReinit` deletes. Once the prefab animation RFC lands, the frame-cycling goes away too — the prefab declares `@animate` and the engine drives it.

### restoreSprites in `save_load.zig`
- **Today:** 80 lines walking Rooms, Ships, Items, Workers, decor, and filling in sprites.
- **After:** Gone. Every one of those entities is prefab-sourced; Phase 1 restores their Sprites.

## Open questions

1. **Overrides schema.** Storing the `overrides` blob as an opaque JSON string is simplest, but it leaks inside the save file and bloats it. Alternative: track overrides as a structured `componentDiff` keyed by component name, emitted via the same serde the rest of the save uses. Leaning structured — easier to diff, easier to inspect, easier to extend when a future attribute (animation, etc.) needs to filter specific fields.

2. **Prefab evolution.** If a prefab grew a new component between save and load, the loaded entity gets it (good). If the prefab dropped a component, the saved data for that component is silently discarded in Phase 2 (acceptable — warn in debug). If a component's field changed type, Phase 2's serde fails as it does today.

3. **Non-prefab runtime children.** Any entity created at runtime with `createEntity + setParent` without going through `spawnFromPrefab` is a v2 entity. It saves/loads flat — so its non-saveable render components are still lost. For now games opt in by migrating to `spawnFromPrefab`. A future extension: let games register a **rehydrator hook** on a marker component that the engine calls during Phase 1.

4. **Transient vs saveable on the PrefabChild marker.** `PrefabChild` needs to survive save/load (so Phase 1 can map old IDs to new IDs). But once a prefab-child's mapping is applied, the `local_path` string never gets looked at again at runtime. Fine to keep it saveable; it's ~30 bytes per child. The question is whether we also need to store it in memory at runtime (yes — to re-emit it on a subsequent save).

5. **Cycles in prefab references.** Out of scope v1. Prefab A containing prefab B containing prefab A would recurse infinitely; the loader rejects cycles at jsonc-parse time, same rule applies at spawn.

6. **Ordering of Phase 1.** A prefab-root entity whose `overrides` reference other entities via `@ref` needs those others spawned first. Sort by topological order (no-refs first). If there's a cycle in inter-entity refs, load fails with an explicit error rather than silent corruption.

## Phased rollout

- **Phase A — infrastructure.** `PrefabInstance`, `PrefabChild`, `spawnFromPrefab`, save format v3, two-phase load. Lands in a single labelle-engine PR with integration tests and doc updates. v2 saves continue to load through the v2 path; v3 saves carry both shapes.
- **Phase B — jsonc bridge.** `src/jsonc_scene_bridge.zig` tags prefab-spawned entities automatically. No game changes needed; games immediately see smaller save files and cleaner loads because every scene-jsonc-sourced entity now goes through Phase 1.
- **Phase C — flying-platform-labelle pilot.** Delete `RoomDecor`, delete most of `restoreSprites`, migrate `HydroponicsPlant` to `.transient`. Smoke on F5 → F9. Close out #286.
- **Phase D — animation overlays.** Move `condenser_overlay` / `kitchen_overlay` creation into prefabs + `spawnFromPrefab` calls. Delete `needsReinit` / `initOverlays` reinit dances.
- **Phase E — rehydrator hooks for runtime children.** Optional escape hatch for games that genuinely need runtime-created children outside the prefab system.

Each phase is independently shippable and independently testable.

## Prior art

- **Unity Prefabs** — scene files record each GameObject's prefab source + property overrides; on play, the editor instantiates the prefab and overlays the overrides.
- **Unreal Engine Actor spawning** — `Actor` instances in a Level record the archetype (the `UClass`) and per-instance property deltas. Save slots round-trip these deltas, not full Actor state.
- **Godot Scene instancing** — scenes reference child scenes by path; instance-specific overrides live on the parent scene. Same two-phase concept as proposed here.

All three engines converged on "record the source + overrides, instantiate + apply" as the simplest durable shape. This RFC applies the same pattern to labelle.

## Relationship to recent work

- **Built on** engine #467 (postLoad on nested entities) — Phase 2 needs nested postLoad to fire.
- **Built on** engine #470 (Parent persistence) — prefab-sourced children need their Parent remapped to the new root ID; Parent carrying through the save is a prerequisite.
- **Enables deletion of** flying-platform-labelle #286's game-side work (`RoomDecor`), `HydroponicsPlant.saveable`, and most of `restoreSprites`.
- **Enables deletion of** the `needsReinit` hardening we've been iterating on in `condenser_animation.zig` / `kitchen_animation.zig`.

## Acceptance criteria for Phase A

1. Integration test: save a world with a prefab-sourced entity + children, `resetEcsBackend`, load, assert all children exist with their prefab-authored components (including a non-saveable render-like component) and Phase 2 overrides applied.
2. Integration test: destroy a prefab-spawned child at runtime, save, load, assert that child is NOT present after load.
3. Integration test: v2 save file loads unchanged through the v2 path (no Phase 1 entered).
4. `labelle run --scene=save_load_prefab_smoke --timeout=10s` on a downstream game confirms visual round-trip without any game-side re-hydration.
