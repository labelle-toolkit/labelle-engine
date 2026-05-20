# RFC: Unify Scenes and Prefabs

**Status:** Draft
**Author:** Alexandre
**Date:** 2026-05-20

## Problem

Scenes and prefabs do almost the same thing — describe a tree of entities and their components — but the engine treats them as two separate concepts with two separate file formats, two separate code paths, and two separate sets of assumptions about lifecycle. The asymmetry is small, and that's exactly why it keeps biting us: most of the time the two are interchangeable, until one corner case reveals that the engine remembered one and forgot the other.

Recent bugs that all share the same shape — "the engine treated scene entities differently from prefab entities, by accident":

- **labelle-engine #467** — Nested scene entities didn't fire `postLoad`, silently breaking `Workstation.postLoad`'s slot-table rebuild. The prefab path fired the hook; the scene path didn't.
- **labelle-engine #470** — `Parent` wasn't persisted for scene-rooted entities, so children of parented scene nodes lost their parent on save/load and rendered at raw local position, drifting to scene origin.
- **flying-platform-labelle #286** — Decor children of room prefabs disappeared after F9 because the save-load restore path treated scene roots and prefab roots differently.

Each was a one-line fix in a different place, and each was a separate session of "figure out which code path was the asymmetric one." The structural fix is to remove the asymmetry: **make scenes a special case of prefabs (or rather, make them not special at all)**, so there's one file format, one loader, one lifecycle, one save/load path.

Today's file shapes:

```jsonc
// scenes/main.jsonc — today
{
    "name": "main",
    "assets": ["background", "cloud", "characters", "rooms", "ship", "objects"],
    "entities": [
        { "prefab": "background_sky", "components": { "Position": { "x": 0, "y": 768 } } },
        { "prefab": "ship_carcase",   "components": { "Position": { "x": 0, "y": 0   } } }
    ]
}
```

```jsonc
// prefabs/stair_room.jsonc — today
{
    "components": {
        "Sprite": { "sprite_name": "ladder/ladder_room/ladder_room_bottom.png", ... },
        "Room":   { "room_type": "stair_room", "movement_nodes": [...] }
    },
    "children": [
        { "prefab": "ladder", "components": { "Position": { "x": 54, "y": 0 } } }
    ]
}
```

The grammars are 90% the same. Each entry in `entities` has the same shape as each entry in `children`. The deltas are cosmetic (`entities` vs `children`), structural (scenes have no root entity), and behavioral (scenes declare `assets`, scenes own a camera, scenes bind to game states).

## Proposal

Adopt one unified file format — the **prefab** — that every `.jsonc` under `scenes/` or `prefabs/` follows. The engine builds a single flat registry from both directories. The directories themselves remain as authoring convention (a hint that a file is *likely* to be used as a root vs. a part), but carry no semantics — any prefab can be used as a root, and any prefab can be nested inside another.

### Unified shape

File-level metadata sits at the top of the file. The entity tree lives inside an explicit `"root"` block:

```jsonc
{
    "name"?: "...",             // file-level — registry key, defaults to the filename basename
    "root": {                   // required — the prefab's root entity
        "components"?: { ... }, // optional — components on the root entity
        "children"?:   [ ... ]  // optional — sub-entities (see Child entries)
    }
}
```

A **child entry** follows a slightly different grammar — children are entity descriptors, not whole files, so they don't carry file-level metadata or a `"root"` wrapper. Two disjoint modes:

```jsonc
// inline — defines a fresh entity (may have its own children)
{
    "components"?: { ... },     // components for THIS entity
    "children"?:   [ ... ]      // recursive same grammar
}

// reference — instantiates an existing prefab with optional root-component overrides
{
    "prefab":      "name",      // required — the prefab to instantiate
    "overrides"?:  { ... }      // optional — patched on top of the referenced prefab's root components
}
```

A child entry MUST be one mode or the other. `"components"` is only valid in inline mode; `"overrides"` is only valid in reference mode. Mixing the two is a load-time error.

Reference mode today supports overrides only — it does not append children to the referenced prefab. Authors who need "an existing prefab plus extra children" define a wrapper prefab; this keeps the reuse model explicit and avoids drift from the original prefab's contract.

Every JSON block in the tree corresponds to one entity. The word `"entities"` no longer appears in any file.

### Preserved capability: prefab references inside component data

Today, fields on a component typed `[]const u64` or `[]const Entity` can hold tuples of entity definitions in the source file. The engine detects them at comptime (`labelle-engine/scene/src/entity_writer.zig`'s `isNestedEntityArray` / `hasNestedEntityFields`), spawns the entities, and stores their resulting IDs back into the array. `Room.movement_nodes`, `Room.workstations`, and similar fields use this pattern.

The unified format **preserves this capability unchanged**. Components can continue to hold entity-bearing fields and the same comptime detection runs against them. There are two side-effects of this choice:

- A reference inside a component field uses the reference-mode grammar — `prefab` + `overrides` (B2 applies everywhere prefab refs appear, not just under `children`).
- There remain two structural places where an entity can be born in a file: the `children` array, and inside an entity-bearing component field. Walkers that need to enumerate spawned entities (asset inference, save/load, post-load hook firing, gizmo registration) must traverse both. This asymmetry is a known cost of preserving today's ergonomics; revisiting it is out of scope for this RFC.

### Explicit root entity

Today's scenes have no root entity; their `entities` array spawns world-rooted. Under unification, **every prefab — including ones used as scenes — has a single root entity**, and that root is named explicitly via the `"root"` wrapper at the top of every file. The wrapper is the cornerstone of the proposal because it makes the rest fall out:

- **Lifetime is uniform.** "Unload scene" becomes "destroy the root entity"; the `Parent` cascade does the work. No special scene-unload path.
- **Save/load is uniform.** Serialize the tree rooted at the prefab's root. Same code path for any prefab.
- **Composability is real.** A scene nested inside another scene is just a sub-tree under a parent entity. No "two world roots" problem.
- **Scene-level config rides on the root entity as components** (`AssetManifest`, `CameraSettings`, etc.), fitting the existing ECS pattern instead of growing scene-special fields.
- **File-level vs entity-level concerns are visibly separated.** `"name"` (registry key) at the top; entity content under `"root"`. Future file-level additions — `"version"`, `"imports"`, `"deprecated"` — have a natural home without entangling with the root entity. Tooling (and LLMs authoring or refactoring these files) sees the structure directly rather than inferring it from a convention.

Child positions in scenes today are world-rooted; under unification they become parent-rooted. With the scene's root at `Position { x: 0, y: 0 }` (the default when omitted), the child coordinates are unchanged. No content migration is needed for positions.

## Resolution and naming

### One flat registry

The engine scans both `scenes/` and `prefabs/` recursively and builds one flat name-keyed registry. References (`{ "prefab": "hydroponics" }`) resolve against that registry, regardless of which directory the target file lives in.

### Effective name

```
effective_name(file) =
    file."name" field   if present
    | basename(file)    otherwise
```

The optional `"name"` field is lifted from today's scene format and made available to all prefabs. When absent, the filename basename (without extension) is used. This matches how prefabs are referenced today (`"prefab": "hydroponics"` finds `prefabs/rooms/hydroponics.jsonc`).

### Collisions

If two files resolve to the same effective name, the engine **errors at load time**. There is no precedence rule — collisions are explicit acts that the author can resolve in two ways:

- Rename one of the files, or
- Add `"name": "..."` to one of them with a different value.

Both are visible in code review. A precedence rule (e.g., "scenes win") would quietly paper over collisions and create hard-to-debug bugs when a feature branch happens to introduce one.

### Convention (non-enforced)

Recommend in docs that when `"name"` is set, its value equal the file's basename unless there's a reason to diverge. This keeps the common case predictable while preserving the flexibility for the small number of cases where it actually matters (test fixtures, renames-without-moves, friendlier registry IDs for deeply-nested files).

## Behavior homes

Scene-today behaviors that don't belong in the prefab format itself find new homes — each chosen to fit labelle's existing ECS / convention-based patterns.

### Assets — inferred, with a component escape hatch

Today scenes declare `"assets": ["background", "cloud", ...]` — a list of named resource bundles from `project.labelle`. Under unification:

- **Primary path: inference.** The engine walks the prefab tree at instantiation, collects all `Sprite.sprite_name` references (and prefab-reference-inside-component values like `Room.movement_nodes` and `Room.workstations`), and maps each to its declaring resource bundle via the project's `.resources` declarations. Required bundles are loaded before instantiation.
- **Escape hatch: `AssetManifest` component.** When inference can't see an asset — sounds, atlases referenced only by scripts, atlases lazily attached via runtime overlays — declare it explicitly:

  ```jsonc
  {
      "root": {
          "components": {
              "AssetManifest": { "load": ["intro_audio", "cinematic_overlay"] }
          },
          "children": [ ... ]
      }
  }
  ```

  Any prefab can carry an `AssetManifest`, and nested manifests are unioned with the parent's at instantiation. This composes cleanly: a "test harness" prefab can wrap a real scene and add fixtures' asset deps without touching the scene file.

The `"assets"` field is dropped from every scene file during migration.

### Camera — default inserted by the engine

Today scenes own a camera. Under unification:

- If the instantiated tree contains a `Camera` component anywhere, the engine uses it as-is.
- If not, the engine inserts a default `Camera` entity at world root **only when the prefab is being instantiated as a root** (i.e., via the state-binding entry point). Nested prefabs don't get a default camera — that prevents "two cameras when I instance a scene inside a scene."

Explicit override stays available via a `Camera` component on the root entity:

```jsonc
{
    "root": {
        "components": {
            "Camera": { "x": 0, "y": 0, "zoom": 2.0 }
        },
        "children": [ ... ]
    }
}
```

### Lifecycle — destroy the root entity

Scene swaps today have a bespoke "unload everything" path. Under unification:

- Loading a prefab as the root instantiates its tree and remembers the root entity ID.
- Unloading is destroying that root entity. `Parent` cascade (post-#470) destroys the whole subtree.

This collapses scene-unload and prefab-destroy into the same operation, and is the structural reason save/load and post-load hooks become uniform (the asymmetry from #467 / #470 / #286 goes away).

### State binding — stays in `project.labelle`

State → root-prefab mapping continues to live in `project.labelle`. The field currently named `.initial_scene` is the entry point and is renamed for clarity (see Open Questions). State transitions trigger a root-prefab swap: destroy the current root, instantiate the new one.

## Migration

### File-by-file changes

**Scenes** lose two fields, adopt the `root` wrapper, and rename `"components"` to `"overrides"` on every prefab reference:

1. Delete the `"assets": [...]` field.
2. Rename `"entities"` → `"children"`.
3. Wrap the `"children"` array inside an explicit `"root": { ... }` block.
4. For each entry that has a `"prefab"` field, rename its `"components"` (now overrides) → `"overrides"`. Inline entries (no `"prefab"`) keep `"components"` as-is.
5. The `"name"` field stays at the top (file-level metadata, not inside `"root"`). It can be removed if the file's basename already matches.

**Prefabs** keep their root `"components"` and `"children"` (move them under `"root"`), and apply the same `"components"` → `"overrides"` rename on every nested prefab reference — including references buried inside entity-bearing component fields like `Room.movement_nodes`:

1. Wrap the file's existing `"components"` and `"children"` fields inside `"root": { ... }`.
2. For every entry in `"children"` or inside an entity-bearing component field that has a `"prefab"` key, rename its `"components"` → `"overrides"`.

Both migrations are mechanical and can be done with a `jq`-style script or a one-shot editor pass.

Worked examples, before/after:

```jsonc
// BEFORE — scenes/main.jsonc
{
    "name": "main",
    "assets": ["background", "cloud", "characters", "rooms", "ship", "objects"],
    "entities": [
        { "prefab": "background_sky", "components": { "Position": { "x": 0, "y": 768 } } },
        { "prefab": "ship_carcase",   "components": { "Position": { "x": 0, "y": 0   } } }
    ]
}
```

```jsonc
// AFTER — scenes/main.jsonc
{
    // "name" omitted — defaults to "main" from the filename
    // No "assets" — inferred from Sprite references in the tree
    "root": {
        "children": [
            { "prefab": "background_sky", "overrides": { "Position": { "x": 0, "y": 768 } } },
            { "prefab": "ship_carcase",   "overrides": { "Position": { "x": 0, "y": 0   } } }
        ]
    }
}
```

```jsonc
// BEFORE — prefabs/worker.jsonc
{
    "components": { "Worker": {}, "Health": { "current": 100, "max": 100 } },
    "children": [
        { "components": { "Sprite": { "sprite_name": "thirsty/png/thirsty_0001.png", ... }, "StatusOverlay": { "kind": "thirsty" } } }
    ]
}
```

```jsonc
// AFTER — prefabs/worker.jsonc
{
    "root": {
        "components": { "Worker": {}, "Health": { "current": 100, "max": 100 } },
        "children": [
            // inline child — no "prefab" key, so "components" stays as "components"
            { "components": { "Sprite": { "sprite_name": "thirsty/png/thirsty_0001.png", ... }, "StatusOverlay": { "kind": "thirsty" } } }
        ]
    }
}
```

A prefab that uses both `children` references and embedded entity refs inside component data shows the `components` → `overrides` rename applies in both places:

```jsonc
// BEFORE — prefabs/stair_room.jsonc
{
    "components": {
        "Sprite": { "sprite_name": "ladder/ladder_room/ladder_room_bottom.png", ... },
        "Room": {
            "room_type": "stair_room",
            "movement_nodes": [
                { "prefab": "movement_node",  "components": { "Position": { "x": 20,  "y": 93 } } },
                { "prefab": "movement_stair", "components": { "Position": { "x": 73,  "y": 93 } } },
                { "prefab": "movement_node",  "components": { "Position": { "x": 126, "y": 93 } } }
            ]
        }
    },
    "children": [
        { "prefab": "ladder", "components": { "Position": { "x": 54, "y": 0 } } }
    ]
}
```

```jsonc
// AFTER — prefabs/stair_room.jsonc
{
    "root": {
        "components": {
            "Sprite": { "sprite_name": "ladder/ladder_room/ladder_room_bottom.png", ... },
            "Room": {
                "room_type": "stair_room",
                "movement_nodes": [
                    // refs inside component data — "components" → "overrides"
                    { "prefab": "movement_node",  "overrides": { "Position": { "x": 20,  "y": 93 } } },
                    { "prefab": "movement_stair", "overrides": { "Position": { "x": 73,  "y": 93 } } },
                    { "prefab": "movement_node",  "overrides": { "Position": { "x": 126, "y": 93 } } }
                ]
            }
        },
        "children": [
            // ref under children — same rename
            { "prefab": "ladder", "overrides": { "Position": { "x": 54, "y": 0 } } }
        ]
    }
}
```

Child entries within the tree never gain a `"root"` wrapper — only the file's outermost block does. The two child-entry modes (inline `components` vs. reference `overrides`) apply uniformly wherever a prefab reference can appear: in the `"children"` array, in entity-bearing component fields, and at any depth.

### Loader migration

- Add the `scenes/` directory to the registry scan.
- Detect the legacy keys `"entities"`, `"assets"`, and `"components"` on reference entries; emit a deprecation warning. Treat `"entities"` as a synonym for `"children"`, and treat `"components"` on a reference entry (one with a `"prefab"` field) as a synonym for `"overrides"`. This lets the codebase migrate file-by-file without a single atomic switch. Plan to remove the legacy synonyms after all in-tree files are migrated.

### Engine API

`game.transitionToScene("name")` (or equivalent) keeps working — "scene" is a synonym for "root prefab" at the API level. Renaming the API symbol is out of scope for this RFC and can land separately.

## Out of scope

- Rename of the engine's runtime API surface (`transitionToScene`, etc.).
- Editor / authoring tool changes beyond pointing at the unified registry.
- Hot-reload semantics for the implicit root entity (likely simplified — the same destroy-and-reinstantiate path scenes use today still applies, just on the root).

## Open questions

1. **Rename of `project.labelle`'s `.initial_scene`.** Candidates: `.initial_prefab`, `.entry`, `.entry_prefab`, `.root`, `.initial_root`. Lean toward `.initial_prefab` for symmetry with the unified vocabulary. Keep `.initial_scene` as a legacy alias for one or two release cycles.

2. **Soft convention enforcement.** Should the engine emit a load-time warning when `"name"` is set and doesn't match the filename basename, or stay silent? The doc-only convention is the least intrusive; a lint-style warning catches accidental divergence; an error would be heavy-handed.

3. **`overrides` merge semantics.** With `overrides` as its own keyword (separate from `components`), the merge rules need to be specified precisely in one place: shallow vs deep merge, list-replace vs list-append, what happens to components in the referenced prefab that the override does not mention (kept), how to *remove* a component the referenced prefab has (probably an explicit syntax like `"Position": null`, but worth deciding). The unification doesn't change today's behavior; it just renames the keyword. This is the moment to write the rules down.

4. **Asset inference completeness audit.** Are there atlases or audio banks today that are loaded from scripts, never from a Sprite component? Walk the project before removing the `"assets"` field to make sure inference + `AssetManifest` cover every case. If significant gaps exist, the migration plan grows a "add `AssetManifest` to scenes X, Y, Z" step.

5. **`AssetManifest` lifetime.** When a prefab carrying `AssetManifest` is destroyed, should the listed bundles be reference-counted / unloaded? Probably yes (so a finished cinematic scene releases its audio bank), but the bookkeeping needs to be specified — multiple instantiations of the same prefab should not double-count, and bundles referenced by multiple manifests should only unload when the last manifest is gone.
