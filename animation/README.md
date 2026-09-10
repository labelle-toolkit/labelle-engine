# Animation package — definition foundation

First implementation stage of engine #794 / RFC #793. A top-level package next
to `scene/` and `jsonc/`, independently built and tested with Zig 0.16:

```sh
cd animation
zig build test --summary all
```

This stage owns shared JSONC frame definitions. It does **not** add a second
playback system: existing AnimationDef, SpriteAnimation and engine exports are
unchanged. Moving those implementations behind this package, assembler
discovery/bindings, prefab references, playback, trigger commands, reliable
markers, persistence and pause migration remain subsequent stages.

## Initial schema

Games will store reusable assets under `animations/*.jsonc`. This loader accepts:

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
- Fields for speed, markers and triggers are intentionally not accepted yet.
  This API does not imply that the assembler recognizes new prefab syntax.

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
