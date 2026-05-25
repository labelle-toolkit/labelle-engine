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

Reference mode supports `overrides` and disallows `children`. The two halves of the grammar partition by intent, not by accident:

- **Inline mode is authoring.** You are describing a fresh entity at this point in the file. `children` belongs here because you are building something — nesting is part of the description.
- **Reference mode is instantiating.** You are calling out to an existing recipe. `overrides` belongs here because instantiation legitimately needs to tune the call site (a different position, a different label). Appending `children` would not be tuning the call — it would be quietly re-authoring the recipe at the use site.

Put plainly: **authoring lets you nest; instantiating doesn't.** Inside a file is authoring, so `children` is freely allowed (a prefab's own file can declare any tree it wants). Pointing at someone else's file is instantiating, so only `overrides` is allowed at that site — no `children` appended.

If a use site needs an authored variant ("the door from `door.jsonc`, but with a pressure-plate child"), the variant gets its own file. That file *is* the authoring; the wrapper prefab is not a workaround for a missing feature, it is the place the new contract lives. Reviewers see a named variant, scripts can spawn it by name, and the original prefab's contract is unchanged for every other use.

**Behavior change from the current loader.** Today's `jsonc/scene_loader.zig:683-704` explicitly accepts both prefab children and appended call-site children at a reference site (the second `if` branch under the "Process children (prefab children + inline children)" comment). The unified loader (#561/#573) must reject this shape at load time, not silently accept it. A scan of `flying-platform-labelle` at the time of writing shows zero existing files use the pattern, so no content migration is required — but the pre-flight audit from #570/#575 should be extended to flag any occurrences before #573 lands, so a stray case can't sneak in through a branch that wasn't surveyed.

Every JSON block in the tree corresponds to one entity. The word `"entities"` no longer appears in any file.

### Examples

Four shapes cover the patterns you'll see in practice. Each is a complete file under `<project>/prefabs/`.

**1. Single semantic entity.** One root entity with its own components, no children. The simplest possible prefab.

```jsonc
// prefabs/furniture/bed.jsonc
{
    "root": {
        "components": {
            "Position": { "x": 0, "y": 0 },
            "Sprite":   { "name": "bed" },
            "Bed":      { "occupancy": 1 }
        }
    }
}
```

**2. Collection prefab (aggregator root).** The root has no semantic role beyond `Position`; its job is identity and parenting. The children are prefab references — this prefab composes other prefabs.

```jsonc
// prefabs/rooms/kitchen.jsonc
{
    "root": {
        "components": {
            "Position": { "x": 0, "y": 0 },
            "Room":     { "name": "kitchen" }
        },
        "children": [
            { "prefab": "stove",   "overrides": { "Position": { "x": -32, "y": 0 } } },
            { "prefab": "fridge",  "overrides": { "Position": { "x":  32, "y": 0 } } },
            { "prefab": "counter", "overrides": { "Position": { "x":   0, "y": 24 } } }
        ]
    }
}
```

The kitchen's root is the parent of all three appliances. Each appliance brings whatever children *its own file* declared — nothing is appended here. Overrides only tune call-site fields (`Position` here).

**3. Authored variant (the "wrapper prefab").** When a use site needs to grow a prefab's content, the growth becomes a new authored entity in its own file. Inline children — full authoring at this level — express "the storage from `eis.jsonc`, plus a starting water item."

```jsonc
// prefabs/storage/eis_with_water.jsonc
{
    "root": {
        "components": {
            "Position": { "x": 0, "y": 0 },
            "Sprite":   { "name": "eis" },
            "Storage":  { "capacity": 8 }
        },
        "children": [
            {
                "components": {
                    "Position": { "x": 0, "y": -4 },  // parent-rooted
                    "Sprite":   { "name": "water_packet" },
                    "Item":     { "kind": "water" }
                }
            }
        ]
    }
}
```

This is a separate, named contract. Scenes referencing `eis_with_water` get the storage *and* the starting item every time; scenes referencing `eis` get a bare storage. Both names show up in code review and in `game.spawn(...)` call sites.

**4. Scene (which is just a prefab used as an entry point).** Same grammar as anything else. Typically an aggregator root that mixes references and inline entities to lay out a level.

```jsonc
// prefabs/scenes/bandit_raid.jsonc
{
    "root": {
        "children": [
            { "prefab": "ship_carcase" },
            { "prefab": "kitchen",         "overrides": { "Position": { "x": 240, "y": 120 } } },
            { "prefab": "eis_with_water",  "overrides": { "Position": { "x": 180, "y":  80 } } },
            {
                "components": {
                    "Position": { "x": 0, "y": 0 },
                    "GameMode": { "kind": "raid" }
                }
            }
        ]
    }
}
```

Three things to notice:

- The scene's root carries no components — `Position` defaults to `{0, 0}` (§"Explicit root entity"), and a default `Camera` is inserted by the engine for state-bound prefabs (§"Camera — default inserted by the engine"). Pure aggregator.
- The `kitchen` reference brings its full sub-tree (stove + fridge + counter); the scene doesn't see them individually.
- The last child is inline — a one-off `GameMode` entity authored directly here because it isn't reused elsewhere. Inline vs. reference is a judgment call: anything reused goes in its own file.

"Scene" is now shorthand for "a prefab the game enters as a top-level state" (§"State binding"). The grammar makes no distinction.

### Preserved capability: prefab references inside component data

Today, fields on a component typed `[]const u64` or `[]const Entity` can hold tuples of entity definitions in the source file. The engine detects them at comptime (`labelle-engine/scene/src/entity_writer.zig`'s `isNestedEntityArray` / `hasNestedEntityFields`), spawns the entities, and stores their resulting IDs back into the array. `Room.movement_nodes`, `Room.workstations`, and similar fields use this pattern.

The unified format **preserves this capability unchanged**. Components can continue to hold entity-bearing fields and the same comptime detection runs against them. There are two side-effects of this choice:

- A reference inside a component field uses the reference-mode grammar — `prefab` + `overrides` (B2 applies everywhere prefab refs appear, not just under `children`).
- There remain two structural places where an entity can be born in a file: the `children` array, and inside an entity-bearing component field. This asymmetry is a known cost of preserving today's ergonomics; revisiting it is out of scope for this RFC.

To avoid recreating the same bug class at a smaller scale, #561 must introduce one shared entity-tree walker utility. Asset inference, save/load enumeration, post-load hook dispatch, gizmo registration, and any future "visit every spawned entity" consumer call that utility rather than each writing its own traversal. The utility is responsible for visiting both `children` and entity-bearing component fields in file order, following referenced prefabs with cycle detection, and surfacing a single callback shape for "inline entity" vs "prefab reference + overrides". Consumers can layer their own behavior on top, but they do not get to choose a traversal subset by accident.

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

Because #561 merges two previously separate namespaces, the implementation must start with a pre-flight audit command/check that scans current `scenes/` and `prefabs/` using the same effective-name rule and reports collisions before enabling the merged registry by default. A project can plausibly have both `scenes/foo.jsonc` and `prefabs/foo.jsonc` today; that pair must be identified as a migration item, not discovered only after the loader path flips.

### Override merge semantics

The `components` -> `overrides` rename preserves the existing prefab-reference behavior:

- The referenced prefab's root components are created first.
- An override for an existing component is a **shallow struct-field overlay**: start from the prefab-authored component value, then replace each field named by the override. Nested structs and lists are replaced as whole field values, not deep-merged or appended.
- An override that names a component absent from the referenced prefab adds that component to the instantiated root.
- Components omitted from `overrides` are kept unchanged.
- Nested entity-array fields inside an override keep today's special case: the merge skips them because the loader expands those definitions into entity IDs separately.

Component removal is the only new surface area and stays with #562: decide whether a syntax like `"Position": null` is supported, and if so whether removal can affect required engine components.

### Convention (non-enforced)

Recommend in docs that when `"name"` is set, its value equal the file's basename unless there's a reason to diverge. This keeps the common case predictable while preserving the flexibility for the small number of cases where it actually matters (test fixtures, renames-without-moves, friendlier registry IDs for deeply-nested files).

## Behavior homes

Scene-today behaviors that don't belong in the prefab format itself find new homes — each chosen to fit labelle's existing ECS / convention-based patterns.

### Assets — inference + lazy fallback over `AssetCatalog`

Today scenes declare `"assets": ["background", "cloud", ...]` — a list of named resource bundles from `project.labelle`. Under unification the field is dropped; loading is driven by inference, with an explicit-declaration escape hatch and a lazy-on-miss safety net.

The mechanism builds on `AssetCatalog` (`labelle-engine/src/assets/`, introduced by RFC-ASSET-STREAMING), which already provides:

- A registry of declared assets keyed by name; each entry has a state (`registered → queued → decoding → ready/failed`) and a refcount.
- Worker-thread decode (3 workers, SPSC ring buffers).
- Main-thread upload with a per-frame budget.
- Refcounted unload — assets drop back to `registered` when refcount hits zero, GPU memory freed.

The unification adds two things on top: a **reverse index** mapping sprite/image names to their containing assets, and a **walker** that pre-computes per-prefab required-resources at engine startup. Acquire/release calls into `AssetCatalog` are made at top-level spawn / destroy.

#### Reverse index (built once at engine startup)

```zig
const ResourceRef = union(enum) {
    atlas: []const u8,   // bundle name (the atlas that contains this sprite)
    image: []const u8,   // asset name (the standalone image itself)
};
const reverse_index: std.StringHashMap(ResourceRef);
```

Built by parsing every entry in `project.labelle`'s `.resources`:

- An entry with `.json` (atlas + JSON metadata): parse the JSON, extract every sprite path, insert `(sprite_path → .{ .atlas = bundle_name })`.
- An entry without `.json` (standalone image): insert `(asset_name → .{ .image = asset_name })`.

**Collisions** (two atlases declaring the same sprite path, or any other name conflict): **load-time error at engine startup**. Exact-match comparison, case-sensitive. The cost of being strict is "rename a duplicate sprite"; the cost of being lenient is silent shadowing bugs that only manifest under specific atlas-load orders.

#### Walker (runs once per prefab at engine startup)

For every prefab in the registry, walk the static tree once and produce `prefab_name → required_resources[]`:

- Recurse through `children` array entries.
- Recurse through nested prefab references inside entity-bearing component fields (the preserved C1 pattern — `Room.movement_nodes`, `Room.workstations`, etc.).
- For every component value, walk every nested struct/array/string field. For each string, look it up in the reverse index. Hits add the resource to the prefab's required set.
- Union with `AssetManifest.load` declarations found on any entity in the tree.

The walker treats false positives (a string that happens to match a sprite name but isn't a visual reference) as harmless — they pre-load an unneeded resource. The alternative (per-component declaration of which fields are visual refs) would force every component author to remember to declare, and missed declarations would cause silent missing-texture bugs at runtime.

"Harmless" here means correctness-harmless, not cost-free. A false positive can load an unneeded atlas, which matters on memory-constrained Android targets. The #566 audit must measure this risk in real projects and either accept it explicitly for v1 or narrow the inference rule (for example, by preferring known visual component fields and falling back to `AssetManifest` for script-only assets). Lazy-on-miss already makes false negatives recoverable via pop-in, so mobile memory pressure is allowed to bias the final rule toward less eagerness if the audit finds large over-loads.

#### Asset acquire / spawn / release lifecycle

Every asset-owning prefab instantiation (a state transition or `game.spawn(prefab_name)` from a script):

```
required = prefab_required_resources[name]   // pre-computed
for each r in required:
    assets.acquire(r)
wait until assets.allReady(required)         // loading scene masks this
spawn entity tree
remember `required` on the spawned root entity
```

Children spawned as part of the tree do NOT acquire — the asset-owning spawn's recursive `required` set already includes their resources. This notion of "asset-owning spawn" is broader than "state root": script calls to `game.spawn(prefab_name)` acquire and release their own resources, but they are not state entry points and do not receive state-only behavior such as default camera insertion.

On root destruction:

```
for each r in remembered:
    assets.release(r)
```

#### Lazy on-miss (async pop-in)

When `findSprite` / `findImage` misses (sprite or image name not in any currently-loaded resource):

```
r = reverse_index[name]
if r != null and assets state != .failed:
    assets.acquire(r)        // attribute to active state's world root
    return null this frame   // renderer skips
else:
    log "unknown sprite/image: <name>" once per name
    return null permanently
```

The renderer treats a null lookup as "skip this entity's visual this frame." When the load completes (`assets.isReady(r)`), subsequent frames render normally. The sprite or image pops in.

Lazy acquires are tracked on the **active state's world root**, not per-entity. They're released at the next state transition. This keeps bookkeeping simple at the cost of holding lazy-loaded resources slightly longer than strictly needed.

#### State transition ordering

State A → State B:

```
new_required = prefab_required_resources[B]
for each r in new_required:
    assets.acquire(r)          // *** acquire NEW first ***
wait until assets.allReady(new_required)
spawn B's tree
for each r in (A's tracked set ∪ A's lazy set):
    assets.release(r)          // *** release OLD after ***
destroy A's tree
```

Acquire-new-first means resources shared between A and B never see refcount zero — no thrashing reload. Resources only-in-A unload after the swap; resources only-in-B load fresh.

#### Loading scene pattern

The wait between acquire-new and spawn-B is masked by the existing loading-scene pattern: the old (loading) state stays alive and rendering until the new state is ready. Nothing new — `AssetCatalog` already exposes:

- `assets.progress(slice) → ratio` for the loading bar.
- `assets.allReady(slice) → bool` for the transition trigger.
- `assets.lastError(name)` for failure surfaces.

The engine adds an API for the loading script to discover which resources are in flight (proposed: `game.pendingTransitionResources() → []const []const u8`). The loading script polls `assets.progress(...)` on that slice each frame and renders accordingly.

#### `AssetManifest` component (eager escape hatch)

When the walker can't see an asset — script-computed sprite names, runtime overlays, audio banks, raw bytes loaded by scripts — declare it explicitly on the prefab that needs it eagerly:

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

`AssetManifest` declarations are merged into the prefab's `required_resources` set by the walker (at engine startup). Any prefab can carry one, anywhere in the tree — nested manifests are unioned with the root's set. This composes cleanly: a "test harness" prefab can wrap a real scene and add fixture asset deps without touching the scene file.

Lifetime semantics for manifest-declared resources match inference-derived ones: acquired at top-level spawn, released at root destruction.

#### Standalone `Image` component

Today entities can only display images via atlas-sprites (`Sprite.sprite_name` → `TextureManager.findSprite`). The unification adds an `Image` component for entities that need a standalone PNG (no atlas, no sub-rect):

```jsonc
"Image": {
    "name": "logo_splash",       // AssetCatalog asset key
    "pivot": "bottom_left",      // same enum as Sprite
    "layer": "ui",               // same layering as Sprite
    "z_index": 10,               // same
    "visible": true              // optional
}
```

The walker treats `Image.name` references the same as `Sprite.sprite_name` references — both resolve through the unified reverse index above. `AssetCatalog.acquire` / `isReady` / `getTexture` drive the load.

V1 scope is deliberately narrow: no animation, no dynamic name swapping, no sub-rect cropping. If those are needed, use `Sprite` + an atlas. The `Image` component is for single static PNG entities only.

`.resources` declarations in `project.labelle` accept both shapes by making `.json` optional — presence selects the atlas loader, absence selects the catalog `image` loader:

```
.resources = .{
    .{ .name = "rooms",        .json = "assets/rooms.json", .texture = "assets/rooms.png" },  // atlas
    .{ .name = "logo_splash",  .texture = "assets/logo.png" },                                  // standalone
}
```

A naming caveat: there's already a `gui_types.Image` in the imgui layer. The ECS `Image` component is distinct (different module, different render path). Worth a docs callout to avoid confusion.

### Camera — default inserted by the engine

Today scenes own a camera. Under unification:

- If the instantiated tree contains a `Camera` component anywhere, the engine uses it as-is.
- If not, the engine inserts a default `Camera` entity at world root **only through the state-binding entry path** (`project.labelle` initial state / state transition). Nested prefabs and script-driven `game.spawn(prefab_name)` calls do not get a default camera — that prevents "two cameras when I instance a scene inside a scene" and avoids conflating asset-owning script spawns with state roots.

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

- Before enabling the merged registry, run the effective-name collision audit across both directories and resolve any duplicates (`scenes/foo.jsonc` + `prefabs/foo.jsonc`, explicit `"name"` duplicates, or basename duplicates in nested folders).
- Add the `scenes/` directory to the registry scan.
- Detect the legacy keys `"entities"`, `"assets"`, and `"components"` on reference entries; emit a deprecation warning. Treat `"entities"` as a synonym for `"children"`, and treat `"components"` on a reference entry (one with a `"prefab"` field) as a synonym for `"overrides"`. This lets the codebase migrate file-by-file without a single atomic switch. Plan to remove the legacy synonyms after all in-tree files are migrated.

### Engine API

`game.transitionToScene("name")` (or equivalent) keeps working — "scene" is a synonym for "root prefab" at the API level. Renaming the API symbol is out of scope for this RFC and can land separately.

## Out of scope

- Rename of the engine's runtime API surface (`transitionToScene`, etc.).
- Editor / authoring tool changes beyond pointing at the unified registry.
- Hot-reload semantics for the implicit root entity (likely simplified — the same destroy-and-reinstantiate path scenes use today still applies, just on the root).

## Save-file compatibility

Inventing a root entity for scenes changes the persisted tree shape for any save format that records scene-rooted entities directly. #561 should not silently reinterpret old saves as already-rooted trees. The migration plan needs an explicit save-version gate: either old saves are declared unsupported across this RFC boundary, or the loader recognizes the previous scene-rooted format and wraps those entities under the new synthetic root during load. The choice is project policy, but the break must be visible rather than accidental.

## Open questions

1. **Rename of `project.labelle`'s `.initial_scene`.** Candidates: `.initial_prefab`, `.entry`, `.entry_prefab`, `.root`, `.initial_root`. Lean toward `.initial_prefab` for symmetry with the unified vocabulary. Keep `.initial_scene` as a legacy alias for one or two release cycles.

2. **Soft convention enforcement.** Should the engine emit a load-time warning when `"name"` is set and doesn't match the filename basename, or stay silent? The doc-only convention is the least intrusive; a lint-style warning catches accidental divergence; an error would be heavy-handed.

3. **Component removal in `overrides`.** The behavior-preserving merge rules are specified above: shallow component-field overlay, list/struct field replacement, omitted components kept, new components added. The remaining new decision is whether to support removing a component from the referenced prefab (probably an explicit syntax like `"Position": null`, but worth deciding), and whether some engine-required components are protected from removal.

4. **Asset inference completeness and over-load audit.** Are there atlases or audio banks today that are loaded from scripts, never from a Sprite/Image component reference or in a static prefab field the walker can see? Conversely, does the every-string rule pull in large false-positive atlases on Android/mobile targets? Walk the project before removing the `"assets"` field to make sure inference + `AssetManifest` + lazy-on-miss cover every case in practice without unacceptable memory over-load. If significant gaps exist, the migration plan grows a "add `AssetManifest` to scenes X, Y, Z" step; if significant false positives exist, the inference rule narrows before shipping.

5. **Engine API for pending-transition resources.** The loading scene needs to know which resources are in flight for the next state to drive its progress bar. Proposed shape: `game.pendingTransitionResources() → []const []const u8`. Alternative: a callback API on `game.transitionToRoot(name, .{ .on_progress = fn(ratio: f32) {} })`. Decide whichever feels more idiomatic.

### Resolved during RFC discussion (not blocking)

- **`AssetCatalog` foundation.** The unification reuses `AssetCatalog`'s existing refcount, async decode, and frame-budgeted upload. No new async infrastructure introduced by this RFC.
- **Walker scope.** A single shared entity-tree walker visits `children` and entity-bearing component fields; asset inference currently walks every string in component data against the reverse index, with #566 auditing mobile over-load risk before finalizing the rule. Resolves Q1's traversal-shape concern without pretending false positives are free.
- **When inference runs.** Two phases — Phase A builds the reverse index + per-prefab required-resources at startup; Phase B looks up and acquires at top-level spawn. Resolves Q2.
- **Reverse-index collisions.** Load-time error at engine startup, case-sensitive exact match. Resolves Q3.
- **Late spawns / lazy fallback.** Lazy async pop-in via `findSprite` / `findImage` miss → `assets.acquire` attributed to the active state's world root, released at next state transition. Resolves Q4.
- **Acquire/release lifecycle.** Per-top-level-spawn, with acquire-new-first / release-old-after ordering on state transitions to avoid thrashing shared resources. Resolves Q5.
- **Image vs Sprite.** Two distinct components, each with one job. Image is for standalone PNGs via `AssetCatalog`; v1 scope explicitly excludes animation, dynamic name swapping, and sub-rect cropping.
- **Flat-list sugar for aggregator scenes (rejected).** Considered allowing pure-aggregator files to be authored as a top-level list (`[ {prefab:...}, ... ]`) with the loader synthesizing an empty root. Saves ~4 lines per file. Rejected because: (a) the moment a file needs a root component, a `name` override, or any future file-level metadata it must be rewritten into the rooted form — a cliff that's invisible until you hit it and forces a full-file diff; (b) the cases where the sugar helps (no root components, no metadata) are already the simplest files, where authoring time isn't the bottleneck; (c) two surface shapes for the same runtime forces every tool that *writes* files (migrator, editor save path, sidecar JSON) to pick a canonical form, eroding any "I authored it this way" benefit. The rooted form is canonical everywhere.
