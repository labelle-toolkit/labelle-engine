# RFC: Prefab-Driven Sprite Animation

**Status:** Draft
**Author:** Alexandre
**Date:** 2026-04-23

## Problem

Every simple sprite animation in flying-platform-labelle is hand-rolled as its own tick script. They all do the same handful of things — cycle a frame array at a fixed rate, swap a sprite based on a component field, hide the sprite between states — but each gets a bespoke implementation, its own state struct, and its own post-load recovery path.

Concrete headcount in the game today:

- **`scripts/condenser_animation.zig`** — 6-frame pipe cycle + 2-frame shake cycle, gated on a worker processing the workstation. ~250 lines including state management + `needsReinit` dance.
- **`scripts/kitchen_animation.zig`** — 7-frame smoke + 5-frame sink, same shape as condenser. Another ~250 lines, near-copy.
- **`scripts/hydroponics_animation.zig`** — not really animation: picks one of 4 sprites based on `TendableWorkstation.level`, hides below level 2. Plus a Sprite re-add block for save/load recovery. ~140 lines.
- **Condenser/kitchen `initOverlays`** — runtime `createEntity + setParent + addSprite` per workstation, complete with cached-state management that's broken in subtle ways after save/load (we spent six iterations of flying-platform-labelle #286 hardening `needsReinit`).

None of these does anything interesting per-file. They're all the same three shapes:

1. **Frame cycle** — walk an array of sprite names at N fps, optionally gated by a predicate.
2. **Field-driven selection** — read a field on another component (TendableWorkstation.level, Worker.job_state, …) and pick a sprite from a map.
3. **Visibility toggle** — hide the sprite outside certain states (hydroponics plant at level 0/1).

The engine has a sophisticated animation system (`animation_def.zig` → `AnimationDef(zon)`) tuned for characters: multiple clips × multiple variants × many frames, precomputed sprite tables, enum-typed clip/variant. It's great for workers (`walk` / `idle` / `carry` × `m_bald` / `w_brown` / …). It's overkill for "cycle 6 pipe frames." The gap between "one-clip frame cycle" and `AnimationDef` is where every hand-rolled animation script lives.

## Proposal

Add two engine-side components that drive sprite mutation declaratively:

- **`SpriteAnimation`** — cycles `Sprite.sprite_name` through a frame array at a fixed rate.
- **`SpriteByField`** — picks `Sprite.sprite_name` from a map keyed by the runtime value of a named field on another component on the same entity (or its parent).

Games declare them in prefabs like any other component. The engine runs one tick system per component type and mutates `Sprite` as needed. Entities without either component don't pay any cost.

Combined with the save/load-for-prefabs RFC, runtime overlays live in prefabs, save/load just re-instantiates them, and the hand-rolled animation scripts delete.

## Goals

1. **Declarative animations authored in prefabs** — no script per animation.
2. **Composable** — attach/detach at runtime like any other ECS component; multiple animation components on one entity coexist without interference.
3. **Zero allocation at tick time.** Frame arrays are comptime or loaded once; tick just advances an integer.
4. **Consistent with existing engine.** `AnimationState` stays for character-style animation; these components cover the simple case that was previously hand-rolled.
5. **Clean save/load story.** In-flight `timer` / `frame` skipped from save via `Saveable.skip`. Re-instantiation from a prefab re-adds the component; the animation starts at frame 0. (Acceptable — the one-frame visual glitch is invisible at 60fps, and a shipping game cares more about the save being small and deterministic than exact animation continuity across F9.)

## Non-goals

- **Characters.** `AnimationDef` + `AnimationState` stay for clip/variant character animation. This RFC is for everything else.
- **Tweening / easing.** Not a frame animator; no interpolation between keyframes, no bezier curves. If you need tweening, the component is the wrong tool — write a script.
- **Audio sync.** Frame-to-sound triggering is its own concern; out of scope here.
- **Animation graphs / state machines.** No transitions, no blend. If the animation needs states, attach and detach components from a script.

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  Prefab (jsonc) or runtime attach                                │
│    Sprite + SpriteAnimation { frames, fps, mode }                │
│    Sprite + SpriteByField { component, field, map }              │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Engine tick (once per component type)                           │
│    For SpriteAnimation:                                          │
│      view(.{ SpriteAnimation, Sprite }, .{})                     │
│        advance timer; on frame flip, write Sprite.sprite_name    │
│        + source_rect + texture; markVisualDirty                  │
│    For SpriteByField:                                            │
│      view(.{ SpriteByField, Sprite }, .{})                       │
│        read field value on target component; look up in map;     │
│        on change, write Sprite fields; markVisualDirty           │
└──────────────────────────────────────────────────────────────────┘
```

Both live in labelle-engine (or labelle-gfx — see open questions). No changes to `Sprite` itself.

## `SpriteAnimation`

```zig
pub const AnimationMode = enum { loop, once, ping_pong };

pub const SpriteAnimation = struct {
    pub const save = Saveable(.saveable, @This(), .{
        .skip = &.{ "timer", "frame", "forward" },
    });

    frames: []const []const u8,
    fps: f32,
    mode: AnimationMode = .loop,

    // runtime state — excluded from save; re-instantiation from prefab
    // resets to frame 0 which is fine for cycling animations.
    timer: f32 = 0,
    frame: u8 = 0,
    forward: bool = true,  // for ping_pong
};
```

**Tick semantics:**

- `.loop` — `frame = @intFromFloat(@mod(timer * fps, @as(f32, @floatFromInt(frames.len))))`. Classic cycle. (Both `@mod` operands must be the same type; `frames.len` is `usize` and needs the explicit float cast.)
- `.once` — plays through `frames` once; stays on the last frame after. Game can remove the component to replay.
- `.ping_pong` — plays forward to `frames.len - 1`, then backward to 0, flipping `forward` each end.

**Frame flip triggers** `markVisualDirty(entity)`. Idle entities (same frame as last tick) write nothing.

**Example prefab** — condenser pipe overlay:

```jsonc
{
    "components": {
        "Position": { "x": -30, "y": -47 },
        "Sprite": {
            "sprite_name": "condenser/condenser_pipe/condenser_pipe_0001.png",
            "pivot": "bottom_left",
            "layer": "world",
            "z_index": -4
        },
        "SpriteAnimation": {
            "frames": [
                "condenser/condenser_pipe/condenser_pipe_0001.png",
                "condenser/condenser_pipe/condenser_pipe_0002.png",
                "condenser/condenser_pipe/condenser_pipe_0003.png",
                "condenser/condenser_pipe/condenser_pipe_0004.png",
                "condenser/condenser_pipe/condenser_pipe_0005.png",
                "condenser/condenser_pipe/condenser_pipe_0006.png"
            ],
            "fps": 6,
            "mode": "loop"
        }
    }
}
```

## `SpriteByField`

```zig
pub const SpriteByFieldSource = enum { self, parent };

pub const SpriteByField = struct {
    pub const save = Saveable(.saveable, @This(), .{
        .skip = &.{"last_sprite_ptr"},
    });

    component: []const u8,    // component name on target entity
    field: []const u8,        // field name on that component, integer or enum
    source: SpriteByFieldSource = .self,
    // Parallel arrays: entries[i].key matches field value => entries[i].sprite_name.
    // null sprite_name means "hide" (set Sprite.visible = false).
    entries: []const Entry,

    // runtime state (skipped from save): last sprite_name.ptr written, used
    // to skip markVisualDirty when nothing changed.
    last_sprite_ptr: ?[*]const u8 = null,

    pub const Entry = struct {
        key: i32,  // signed so `-1 = unset` and other sentinel values work
        sprite_name: ?[]const u8,
    };
};
```

**Example** — hydroponics plant overlay (currently `hydroponics_animation.zig`, ~140 lines → 0 lines):

```jsonc
{
    "components": {
        "Position": { "x": 0, "y": -41 },
        "Sprite": {
            "sprite_name": "nursery/nursery_sapling/nursery_sapling_room1_lvl1.png",
            "pivot": "bottom_center",
            "layer": "world",
            "z_index": -3
        },
        "SpriteByField": {
            "component": "TendableWorkstation",
            "field": "level",
            "source": "parent",
            "entries": [
                { "key": 0, "sprite_name": null },
                { "key": 1, "sprite_name": null },
                { "key": 2, "sprite_name": "nursery/nursery_sapling/nursery_sapling_room1_lvl1.png" },
                { "key": 3, "sprite_name": "nursery/nursery_sapling/nursery_sapling_room1_lvl2.png" },
                { "key": 4, "sprite_name": "nursery/nursery_green/nursery_green_room1_lvl1.png" },
                { "key": 5, "sprite_name": "nursery/nursery_green/nursery_green_room1_lvl2.png" }
            ]
        },
        "HydroponicsPlant": {}
    }
}
```

`HydroponicsPlant` reduces to a pure role marker (`.transient` save policy) — it's still useful for scripts that want to find plant entities, but no longer carries the re-hydration burden. The entire `hydroponics_animation.zig` file deletes.

**Component lookup.** `component` is resolved via the game's `ComponentRegistry.getType(name)` (same pattern plugin controllers already use — e.g., `libs/production/src/controller.zig:284` and `libs/command_buffer/src/controller.zig:397`). Missing component at the given source → tick skips silently.

**Field extraction.** `std.meta.fieldIndex` + `@field` via comptime-generated switch. Values coerce to `i32`: signed + unsigned integers direct (widening / bounds-checked), enums via `@intFromEnum`. Unsupported field types fail at `spawnFromPrefab` time with a clear error.

## Gating

Some animations should only run in certain states. Condenser pipe + shake only cycle while a worker is processing the workstation.

Two options considered:

**(a) Gate field on `SpriteAnimation`** — `gate_component: ?string`, engine skips ticks when the named component is absent. Simple, but bakes a game-logic predicate into engine component schema. Only handles presence/absence — not field values.

**(b) Runtime add/remove** — game controls presence of `SpriteAnimation` itself. Script adds the component when the condition becomes true, removes it when false.

Leaning **(b)** — strictly more flexible, engine stays ignorant of game-side predicates, and it fits the ECS model where presence *is* the state. The condenser animation becomes a ~20-line script that watches worker processing state and adds/removes `SpriteAnimation` — infinitely simpler than the current implementation, and safe across save/load because the script tick will re-attach on the first frame after F9.

If experience shows that (b) is too verbose for common gating patterns (worker-processing, locked, powered-on), a narrow `SpriteAnimationGated { gate_component }` companion can add later.

## Migration examples

### `condenser_animation.zig` → prefab + ~20 line controller

**Today:** ~250 lines across the script (`initOverlays`, `needsReinit`, tick with per-workstation pipe/shake frame computation, ID caching, save/load reinit dance, `isPipeFrame` / `isShakeFrame` sprite frame validators).

**After:**
- `prefabs/condenser_pipe_overlay.jsonc` + `prefabs/condenser_shake_overlay.jsonc`, each with `Sprite` + `SpriteAnimation`.
- `scripts/condenser_controller.zig` — watches worker processing per condenser; on transition to processing, `addComponent(pipe_entity, SpriteAnimation{…})`; on transition off, `removeComponent(pipe_entity, SpriteAnimation)`. ~20 lines.
- Scene-init spawns pipe + shake overlays once per condenser (via `spawnFromPrefab` from the save/load-prefabs RFC). Save/load Phase 1 re-spawns them.

### `kitchen_animation.zig` — same shape, same delta.

### `hydroponics_animation.zig` → deleted

`SpriteByField` on the plant overlay does the whole job. The plant prefab re-instantiates via the save/load-prefabs RFC; `SpriteByField` runs every tick; level changes update the sprite. `HydroponicsPlant` marker becomes `.transient`.

## Open questions

1. **labelle-engine vs labelle-gfx location.** Both components manipulate `Sprite`, which is gfx-owned. But the tick system is per-frame logic — engine territory. Lean: components live in labelle-gfx (same module as `SpriteComponent`), tick system lives in engine. Same split as today for `AnimationState`.

2. **Atlas lookup on frame swap.** Frame flip overwrites `sprite_name`, `source_rect`, `texture`. `source_rect` + `texture` need an atlas lookup (`game.findSprite(name)`). Cache the resolved values at `spawnFromPrefab` time to avoid re-lookup each frame? Or resolve on every flip? Probably cache — frame arrays are known at spawn time.

3. **Deterministic tick ordering.** If a script mutates `SpriteByField.entries` at runtime (seems unlikely but possible), and the animation tick runs in the same frame, does the script see the before or after? Convention across the existing engine: animation ticks after gameplay scripts, before render. Document explicitly.

4. **Ping-pong edge cases.** Single-frame array + `.ping_pong` = infinite loop on frame 0; validate at spawn time.

5. **Sprite lifetime.** If the underlying sprite name refers to a sprite that isn't in the atlas (typo, stale reference), `findSprite` returns null. Log a warning once per entity, not per tick.

## Phased rollout

- **Phase A — `SpriteAnimation`.** Component + tick system + integration test (loop, once, ping_pong). Migrate condenser overlays as the pilot. Delete `condenser_animation.zig::initOverlays` / `needsReinit` / frame math (still requires the save/load-prefabs RFC for the spawn path).
- **Phase B — `SpriteByField`.** Component + tick system + integration test. Migrate hydroponics plant overlay. Delete `hydroponics_animation.zig`.
- **Phase C — Kitchen.** Migrate `kitchen_animation.zig` overlays. Delete the script.
- **Phase D — Cleanup.** Remove the `isPipeFrame` / `isShakeFrame` sprite validators and `needsReinit` functions from all animation scripts. The RoomDecor-shaped re-hydration story goes away entirely (save/load RFC does the heavy lifting; animation RFC picks up the per-tick mutation).

Each phase is independently shippable and testable.

## Prior art

- **Godot `AnimatedSprite2D`** — a node with a `SpriteFrames` resource that lists animations; the engine plays them by name. Closest match — the component split here is the ECS-idiomatic translation.
- **Unity `SpriteRenderer` + `Animator`** — `Animator` is a state-machine graph, overkill for the use case. Unity's simpler `SpriteAnimation` (deprecated) did what `SpriteAnimation` here does.
- **Bevy `TextureAtlasSprite` + `AnimationPlugin` crates** — community plugins tend to implement exactly `SpriteAnimation { frames, fps }` as their first primitive. Converges on the same shape.

## Relationship to other work

- **Depends on** the save/load-for-prefabs RFC for Phase 1 (without prefab re-instantiation, migrated overlays can't survive F9).
- **Enables deletion of** `condenser_animation.zig`, `kitchen_animation.zig`, `hydroponics_animation.zig`, and the `initOverlays` / `needsReinit` patterns in each. Net: ~600 lines of game code deleted, replaced by two engine components + one engine tick system.
- **Complements** `AnimationDef` / `AnimationState` — character animation stays as-is; this is for the much simpler single-clip case.

## Acceptance criteria

1. Integration test: entity with `Sprite` + `SpriteAnimation { mode: .loop, frames: [a, b, c], fps: 3 }`; advance 1 second; assert frame cycled to expected index and `sprite_name`/`source_rect` updated.
2. Integration test: `.once` mode holds on the last frame after the cycle completes.
3. Integration test: `.ping_pong` reverses at the endpoints.
4. Integration test: entity with `Sprite` + `SpriteByField { component: "Foo", field: "bar" }`; mutate `Foo.bar` to each key; assert `sprite_name` updates to the mapped value; assert `null` sprite_name sets `Sprite.visible = false`.
5. Integration test: `source: "parent"` reads the field from the parent entity, not self.
6. Downstream smoke in flying-platform-labelle: pilot condenser overlay migration, `labelle run --timeout=20s`, save + load, verify pipe + shake animate correctly post-load.
