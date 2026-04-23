# Prefab Foundations — Downstream Migration Guide

Practical checklist for downstream games adopting the save/load-for-prefabs + prefab animation work in [RFC #472](https://github.com/labelle-toolkit/labelle-engine/pull/472). Read the RFC docs for the *why*; this doc is just the *how*.

## Prerequisites

Wait for the engine and core release lines to include:

| Package | Minimum version | Delivers |
|---|---|---|
| labelle-core | 1.12.0 | `PrefabInstance`, `PrefabChild` tracking components |
| labelle-engine | 1.24.0 (pending) | Built-in save/load handlers, `spawnFromPrefab`, scene-bridge auto-tag, two-phase load, `SpriteAnimation`, `SpriteByField` |

Bump in `project.labelle`:

```zig
.core_version = "1.12.0",
.engine_version = "1.24.0",
```

## What Stops Needing To Exist

Once your game is on the versions above, these idioms from the pre-prefab-foundations world become obsolete and can be deleted outright:

### 1. Marker components that exist just to re-add a `Sprite` on load

Example — flying-platform-labelle's `components/room_decor.zig` (`RoomDecor { kind }`) + `scripts/save_load.zig::restoreSprites`'s switch table mapping `kind → sprite_name`.

**Why it goes away:** the prefab already declares `Sprite` on the decor child. After F9, Phase 1 of two-phase load re-instantiates the prefab, which brings the `Sprite` back unchanged. No re-hydration script needed.

**Migration:**
1. Delete the marker component type (`RoomDecor` or analogue).
2. Delete the restore-pass block from your save/load script.
3. Delete the marker `jsonc` attribute from every prefab file that used it.

**Regression check:** F5 → F9 → verify the decor sprites come back at the correct positions.

### 2. `Saveable(.saveable)` on markers whose data is already in the prefab

Example — flying-platform-labelle's `components/hydroponics_plant.zig`, a one-field marker on an overlay child entity.

**Why it goes away:** making the marker `.saveable` was the mechanism that let the game recognise the entity post-load and re-add the `Sprite`. Once prefab re-instantiation does that structurally, the marker doesn't need to persist — every hydroponics plant overlay will be re-created by the prefab on load.

**Migration:**
1. Change `pub const save = Saveable(.saveable, @This(), .{})` → `pub const save = Saveable(.transient, @This(), .{})`.
2. Delete any tick-script block that re-adds `Sprite` to entities carrying the marker but missing the visual.

**Regression check:** same — F5 → F9 and observe the overlay sprite.

### 3. Runtime-overlay `needsReinit` / `initOverlays` scripts

Example — flying-platform-labelle's `scripts/condenser_animation.zig` and `scripts/kitchen_animation.zig` currently own `pipe_entities` / `shake_entities` / `smoke_entities` arrays, track their cached IDs, detect post-load staleness via `needsReinit`, and call `destroyEntity` + `initOverlays` to rebuild.

**Why it goes away:** the runtime-created overlays become children of the workstation prefab, spawned via `spawnFromPrefab` at scene-init. After F9, the two-phase load re-spawns the prefab (including the overlay children). The animation itself is driven by `SpriteAnimation` declared on the overlay child in the prefab — no per-game tick script needed for frame cycling.

**Migration (per animation script):**

1. Move the overlay creation into a prefab. The condenser pipe becomes:
   ```jsonc
   // prefabs/condenser_pipe_overlay.jsonc
   {
     "components": {
       "Position": { "x": -30, "y": -47 },
       "Sprite": { "sprite_name": "condenser/condenser_pipe/condenser_pipe_0001.png", ... },
       "SpriteAnimation": {
         "frames": ["condenser/condenser_pipe/condenser_pipe_0001.png", "…"],
         "fps": 6,
         "mode": "loop"
       }
     }
   }
   ```
2. Replace the script's `initOverlays` runtime creation with `game.spawnFromPrefab("condenser_pipe_overlay", ...)` called once per workstation at scene-init.
3. Delete `needsReinit`, `initOverlays`, the cached `*_entities` arrays, and all the `destroyEntity` bookkeeping.
4. Replace the per-tick frame math with a short controller that adds/removes `SpriteAnimation` based on gate state (e.g. `Worker.job_state == .working`) — or start with no gate at all if the animation should always run.
5. Call `engine.spriteAnimationTick(&game, dt)` from your scene tick slot. The engine handles all frame advancement + atlas resolution + `markVisualDirty`.

**Regression check:** observe the animation runs correctly, check F5 → F9 preserves the visual (no flicker, no missing overlays).

### 4. Field-driven sprite swap scripts

Example — flying-platform-labelle's `scripts/hydroponics_animation.zig` picks a sprite based on `TendableWorkstation.level`.

**Why it goes away:** `SpriteByField` consumes the same field, the same entries table, and rewrites `Sprite.sprite_name` (or hides the sprite on a null entry) declaratively.

**Migration:**
1. Add `SpriteByField { component, field, source, entries }` to the prefab's overlay child:
   ```jsonc
   "SpriteByField": {
     "component": "TendableWorkstation",
     "field": "level",
     "source": "parent",
     "entries": [
       { "key": 0, "sprite_name": null },
       { "key": 1, "sprite_name": null },
       { "key": 2, "sprite_name": "nursery_sapling_lvl1.png" },
       { "key": 3, "sprite_name": "nursery_sapling_lvl2.png" },
       { "key": 4, "sprite_name": "nursery_green_lvl1.png" },
       { "key": 5, "sprite_name": "nursery_green_lvl2.png" }
     ]
   }
   ```
2. Delete the tick script that reads the field and switches the sprite.
3. Call `engine.spriteByFieldTick(&game, dt)` from your scene tick.

**Regression check:** change the driving field at runtime, watch the sprite update. F5 → F9 → confirm the current value's sprite is selected on load.

## Common Gotchas

### `EmptyComponents` in tests

The default `engine.Game` uses `EmptyComponents` — its save mixin iterates an empty registry, so no entities get collected for save/load. Fine for jsonc-parse tests, wrong for save/load tests. Build a proper `TestGame` with your real `ComponentRegistry` when testing round-trip behaviour.

### `[]const u8` fields and arena ownership

`PrefabInstance.path`, `PrefabInstance.overrides`, `PrefabChild.local_path` are string slices. The component does **not** own its backing memory — the engine allocates into `active_world.nested_entity_arena` (lifetime = scene). If you need to construct one yourself, dupe into the arena (not the testing allocator, not the game allocator).

### Scene-declared prefabs vs runtime-spawned prefabs

Both code paths now emit the same `(PrefabInstance, PrefabChild)` tags with identical `local_path` formatting, so the save mixin's two-phase load treats them uniformly. Your game can use either (or both) without divergence.

### Rename safety

If you rename a prefab between saves, `loadGameState` falls back to `createEntity` for entities whose recorded `PrefabInstance.path` no longer resolves. The entity's other saved components still apply — so you get a non-prefab-tagged entity with the saved component values. Visible non-saveable components (sprites, animation overlays) will be missing. This is acceptable but logged as a warning; renaming prefabs between releases is effectively a breaking change for in-flight save files.

## Sequencing

A realistic order for a downstream migration:

1. Bump engine / core versions (`project.labelle`, `labelle.lock`).
2. Build + run — everything should still work, because the new engine auto-tags existing prefab-sourced entities without any game-side changes.
3. Pick one migration target (e.g. `RoomDecor`). Delete the game-side machinery for that target.
4. F5 → F9 smoke — the target should still round-trip because prefab re-instantiation replaces the game-side work.
5. Repeat for the next target.
6. Declare victory; delete the now-empty `restoreSprites` hook entirely.

## Reference implementation

- **Save/load-for-prefabs RFC** — [RFC-SAVE-LOAD-PREFABS.md](../RFC-SAVE-LOAD-PREFABS.md).
- **Prefab-animation RFC** — [RFC-PREFAB-ANIMATION.md](../RFC-PREFAB-ANIMATION.md).
- **Engine chain** — #474 handlers, #482 spawnFromPrefab, #483 scene tag, #484 two-phase load, #485 scene descendants. #475/#480 SpriteAnimation. #476/#481 SpriteByField.
- **First downstream pilot** — flying-platform-labelle (expected as a follow-up once the engine chain merges and engine 1.24 tags).
