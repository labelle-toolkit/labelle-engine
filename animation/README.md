# Animation package — definitions and named markers

Implementation stages for engine #794 / RFC #793. A top-level package next
to `scene/` and `jsonc/`, independently built and tested with Zig 0.16:

```sh
cd animation
zig build test --summary all
```

This package owns JSONC definitions and named markers, the legacy ZON
AnimationDef and RuntimeAnimationDef paths, AnimationState, SpriteAnimation,
SpriteByField, timing vocabulary, and event buffers. It depends on JSONC and
labelle-core's save metadata, but not the engine, renderer, or a concrete ECS.

All animation tests live in `animation/test/`, including engine adapter tests.
From the engine root, run `zig build test-animation-legacy --summary all` to
include those adapters; the ordinary `zig build test` still runs them.
The package's own `zig build test` runs its independent authoring/playback tests.

The engine preserves its public animation exports. ECS ticks, prefab binding,
and hook delivery stay in engine `src/` because they integrate game services.
Trigger commands, persistence and clock migration remain subsequent stages.

## Initial schema

Games store reusable assets under `animations/*.jsonc`. This loader accepts:

```jsonc
{
  "version": 1,
  "clips": {
    "walk": {
      "frames_pattern": "walk_{frame:04}.png",
      "from": 1,
      "to": 12,
    },
    "idle": { "frames": ["tiles/0"] },
  },
}
```

- Exactly one `{frame}` or `{frame:0N}` placeholder. `N` is a decimal width
  from 1 through 10. Padding never truncates larger numbers; no implicit suffix.
- Bounds are unsigned 32-bit integers, inclusive and ascending. A single-frame
  range is valid. At most 255 frames, matching current SpriteAnimation limits.
- Explicit nonempty frame lists are supported. Combining a list with any range
  fields fails. Empty names/keys, duplicate fields/clips, unknown fields,
  unsupported versions and trailing data fail explicitly.
- These are exact atlas keys, not filesystem paths. Parse errors and missing
  resource keys are separate. Rich source-location diagnostics are future work.
- Clips optionally declare named `markers`; see [MARKERS.md](MARKERS.md).
  Clip-level speed and triggers are not accepted yet. Prefab references require
  the assembler integration described below.

## Ownership and resource readiness

`Definition.parse(allocator, source)` copies its input and owns an arena for the
parsed tree and expanded keys. Free or reuse the input immediately after parsing.
Release everything with `definition.deinit()`; do not copy and independently
deinitialize the owning value. `find(name)` returns a borrowed clip. Definitions
can be shared by multiple consumers without per-entity frame expansion.

After the atlas is ready, its owner calls
`definition.firstMissingFrame(context, hasFrame)` with a lookup callback. The
result identifies the clip, zero-based frame index and missing key. Until then,
parse success means structurally valid authoring, not resource availability.
Reload should load/validate a replacement before changing active references;
this stage does not implement swapping or playback reconciliation.

`FrameRange.expand(arena)` is also available to future assembler/loader adapters.
It requires an arena whose lifetime owns both returned slices and strings;
release that arena on any error. Normal callers should use `Definition.parse`,
which handles partial-allocation cleanup automatically.

The package depends on the sibling JSONC package, not the engine, ECS or renderer.
The engine release manifest includes this directory. CI runs its tests on Linux
and Windows, including allocation-failure cleanup and resource validation.

From the engine root, `zig build test-animation --summary all` additionally
feeds a shared loaded definition into two real `engine.SpriteAnimation` values
and checks independent advancement and loop wrap. This compatibility check is
also part of the full engine test step. It is not an assembled-game or renderer
acceptance test; no new prefab authoring syntax is wired into the assembler yet.


## Engine and prefab integration

Place shared definitions in the game's `animations/` directory. An assembler
with JSONC animation discovery embeds them and calls
`game.loadAnimationJsoncSource("animations/props/propeller.jsonc", source)`
before loading scenes. `.zon` files continue to use `AnimationDef` unchanged.

A registered engine `SpriteAnimation` component can select a definition:

```jsonc
"SpriteAnimation": {
    "definition": "animations/props/propeller.jsonc",
    "clip": "spin",
    "fps": 10,
    "mode": "loop"
}
```

`fps`, `mode`, and `speed` remain per-instance settings. The engine binds the
selected clip's shared frame slice while each entity owns its timer, frame,
direction, and pause state. Existing inline `frames` declarations remain valid;
combining them with `definition` is rejected. Definition/clip errors are logged
and the malformed component is not attached, following the scene bridge's
component-application contract.

Use a scene asset manifest containing the selected clip's atlases. The atlas
resolver checks the selected clip after that manifest is ready, logging the
definition, clip, frame index, and exact missing key once and stopping an invalid
clip. Hosts loading assets imperatively can call `validateSpriteAnimation` once
the required atlases are resident. Without a nonempty current-scene manifest,
automatic validation waits for that explicit call. Pending atlas metadata never
counts as resident, and a current manifest restricts validation to its atlases.
Registration and binding do not assume that textures are ready.

The session-owned `Library` copies sources and names and keeps borrows stable
until game deinit. Scene reset/load creates fresh playback state from the prefab
and reuses those definitions. Registering a name twice fails without changing
the existing definition; live definition replacement is not implemented here.
Pack-local discovery and marker/transition schemas remain separate work.

Named marker authoring, traversal budgets and delivery limits: [MARKERS.md](MARKERS.md).
