# RFC Addendum: `overrides` Merge Rules

**Status:** Accepted
**Resolves:** open question 3 of `RFC-UNIFY-SCENES-AND-PREFABS.md` (#560)
**Ticket:** #562

## Scope

In the unified prefab/scene format, a **reference entry** instantiates an
existing prefab and may patch it:

```jsonc
{ "prefab": "hydroponics", "overrides": { "Health": { "current": 30 } } }
```

`overrides` is a map of component-name → patch. This document specifies
exactly how that patch combines with the referenced prefab's components.

The rules apply **everywhere a reference entry can appear** — in a
`children` array, and inside an entity-bearing component field (the
`Room.movement_nodes` pattern). They do **not** apply to the runtime
`game.spawnFromPrefab(name, pos)` path, which takes no overrides.

## The rule, in one line

`overrides` is a **deep merge** onto the referenced prefab's component
set: objects merge recursively, arrays and scalars replace, and a
component whose patch value is `null` is removed.

## Per-case specification

Let *prefab* be the referenced prefab's components and *ov* be the
`overrides` map.

### 1. Component in *prefab* only

Kept verbatim.

### 2. Component in *ov* only

Added to the instance, exactly as written.

### 3. Component in both — deep merge

The component value is merged field by field:

- A field present in *ov* **and** in *prefab*, both **objects** → merge
  recurses into it.
- A field present in *ov* and in *prefab*, not both objects → the *ov*
  value **replaces** the *prefab* value.
- A field present in *prefab* only → **kept**.
- A field present in *ov* only → **added**.

```jsonc
// prefab    Box { "size": { "w": 1, "h": 2 }, "label_len": 5 }
// override  Box { "size": { "w": 9 } }
// result    Box { "size": { "w": 9, "h": 2 }, "label_len": 5 }
//                          ^^^^^^  overridden
//                                  ^^^^^^^ h, label_len inherited
```

A field the override omits keeps the prefab's value. This is the key
change from the pre-#562 behavior, where a partial override of a
component silently reset the unmentioned fields to their struct
defaults.

### 4. Arrays and scalars replace — no element merge

When a field's value is an array (or a string, number, boolean), the
override value replaces the prefab value outright. Arrays are **not**
merged element-wise; there is no append, no index-merge.

```jsonc
// prefab    Tags { "values": [1, 2, 3] }
// override  Tags { "values": [9] }
// result    Tags { "values": [9] }
```

To extend a list, restate it in full. Element-wise list semantics were
considered and rejected: they need a per-element identity (index? key?)
that JSONC component data does not carry, and the failure mode (a
silent wrong-length list) is worse than the verbosity of restating.

### 5. Component removal — `"Name": null`

A component whose override value is JSONC `null` is **removed** from
the instance: it is neither applied nor does its `onReady` / `postLoad`
hook fire. Sibling components are untouched.

```jsonc
// prefab    { "Marker": { "id": 99 }, "Health": { "current": 50 } }
// override  { "Marker": null }
// result    { "Health": { "current": 50 } }   // Marker dropped
```

Removing a component the prefab does not declare is a no-op. Removing
`Position` simply means the instance keeps the engine's default
position — `Position` is not a removable ECS component in the usual
sense.

`null` is only special at the **component** level (a top-level entry of
`overrides`). Inside a component value, `null` is an ordinary field
value: it sets an optional (`?T`) field to null and is otherwise
deserialized normally.

## Lifecycle parity

A merged component fires its `onReady` / `postLoad` hook exactly once,
the same as a non-overridden component. A removed component fires
nothing. Entity-bearing fields (`[]const u64` ref-arrays such as
`Room.movement_nodes`) survive the merge — overriding one field of a
component does not drop the prefab's nested entities declared in
another field; they still spawn.

## Implementation

- `unified_format.mergeValues(base, patch, arena)` — the recursive deep
  merge over JSONC `Value` trees.
- `unified_format.mergedOverride(prefab_components, key, override, arena)`
  — picks the prefab's matching component and merges, or returns the
  override as-is when the prefab has no such component.
- The loader (`scene_loader.zig`) merges per component in
  `loadEntityInternal` and `spawnAndLinkNestedEntities`, and skips a
  `null` override (recording it so the prefab fallback and the
  `onReady` pass skip it too).

Coverage: `spec/override_merge_spec.zig`.
