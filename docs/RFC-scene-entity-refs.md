# RFC: Scene Entity Cross-References

**Issue:** #413
**Status:** Draft

## Problem

Scene files cannot express sibling-to-sibling relationships between entities. Components like `Stored` and `WithItem` require entity IDs that are only known at runtime. This means:

- Test scenes can't pre-populate storages with items
- Any sibling entity-to-entity relationship must be set up by scripts at runtime
- Scene files can only describe isolated entities or parent/child trees, not peer connections

## Existing Infrastructure

The engine already resolves entity references in two contexts:

### 1. Parent/Child Nesting (Scene + Prefab)

Prefabs create child entities through nested arrays. The parent's component stores child IDs, and children back-reference the parent:

```jsonc
// water_well_workstation.jsonc — storages are created as children
{
    "components": {
        "Workstation": {
            "storages": [
                { "components": { "Storage": {}, "Eos": {} } }
            ]
        }
    }
}
```

At load time:
- `Workstation.storages` is populated with child entity IDs
- `Eos.workstation` is set to the parent's ID via `postLoad`

### 2. Save/Load Entity Remapping (labelle-core)

The `Saveable` system declares which fields hold entity refs:

```zig
// Stored component
pub const save = Saveable(.saveable, @This(), .{
    .entity_refs = &.{"storage_id"},
});

// Workstation component
pub const save = Saveable(.saveable, @This(), .{
    .ref_arrays = &.{"storages"},
    .entity_refs = &.{"workstation_id"},
});
```

On save, entity IDs are serialized. On load, the serde layer remaps old IDs to new IDs using `entity_ref_fields` and `ref_arrays` metadata. This remapping is the same operation needed for scene cross-references.

### What's Missing

Parent/child covers vertical references (parent → child, child → parent). Save/load covers ID remapping for persistence. Neither covers **sibling references** — two top-level entities in a scene that need to point at each other without a parent/child relationship.

## Design

### Ref Declaration

Any entity in a scene file can declare a `"ref"` name:

```jsonc
{ "ref": "eos1", "prefab": "eos", "components": { "Position": { "x": -55, "y": 0 } } }
```

Refs are scene-scoped string identifiers. They don't affect the entity at runtime — they're only used during scene loading for cross-reference resolution.

### Cross-Reference Syntax

Component fields declared in `.entity_refs` can use `@name` to reference another entity:

```jsonc
{ "ref": "water1", "prefab": "water", "components": {
    "Stored": { "storage_id": "@eos1" }
}}
```

The `@eos1` string is resolved to the actual `u64` entity ID of the entity declared with `"ref": "eos1"`.

### Full Example: Pre-Populated Storage

```jsonc
{
    "name": "bandit_eos_theft",
    "entities": [
        { "prefab": "ship_carcase", "components": { "Position": { "x": 0, "y": 0 } } },
        { "prefab": "water_well", "components": { "Position": { "x": 0, "y": 0 } } },

        // EOS storage with a water item already inside
        { "ref": "eos1", "prefab": "eos", "components": { "Position": { "x": -55, "y": 0 }, "WithItem": { "item_id": "@water1" } } },
        { "ref": "water1", "prefab": "water", "components": { "Position": { "x": -55, "y": 0 }, "Stored": { "storage_id": "@eos1" } } }
    ]
}
```

### Two-Pass Loading

The current single-pass loader in `jsonc_scene_bridge.zig` creates and configures entities in one sweep. Cross-references require two passes:

**Pass 1 — Create entities, collect refs:**
- Iterate all entities in the scene
- Create each entity and apply non-ref components (Position, Shape, etc.)
- If entity has `"ref"`, store `ref_name -> entity_id` in a `StringHashMap(u64)`
- Defer components that contain `@` values in `.entity_refs` fields

**Pass 2 — Resolve deferred refs:**
- For each deferred component, look up `@name` in the ref map
- Replace with the resolved `u64` entity ID
- Apply the component via `addComponent`

Components without `@ref` fields are applied immediately in pass 1. Existing scenes without `"ref"` follow the single-pass path unchanged.

### Reusing Saveable Metadata

The ref resolution piggybacks on labelle-core's existing `Saveable` metadata:

- **`entity_ref_fields`**: Tuple of field names holding single entity IDs (e.g. `"storage_id"`, `"item_id"`)
- **`ref_arrays`**: Tuple of field names holding arrays of entity IDs (e.g. `"storages"`)

The scene bridge already uses the `Components` registry at comptime to dispatch by component name. Adding ref detection is a comptime check: for each component field in `entity_ref_fields`, check if the JSON value is a string starting with `@`. If so, defer to pass 2.

```zig
// Pseudocode for ref detection in applyComponent:
inline for (T.save.entity_ref_fields) |field_name| {
    if (obj.getString(field_name)) |val| {
        if (val.len > 0 and val[0] == '@') {
            // Defer this component to pass 2
            return;
        }
    }
}
```

### Implementation Scope

**In scope:**
- `"ref"` on top-level scene entities and prefab-spawned entities
- `@name` resolution in component fields listed in `.entity_refs`
- Two-pass loading in `jsonc_scene_bridge.zig`
- Forward and backward references (entity order doesn't matter)

**Out of scope (future work):**
- Refs on nested children (workstation storage children defined inside prefabs)
- Refs in prefab files themselves
- Path-based refs for nested children (`@water_well/eos/0`)
- Refs in `spawnPrefab` at runtime

### Nested Children

Workstation storages (EOS, EIS, etc.) are nested children defined inside prefab files. They can't be referenced from the scene because they don't appear as top-level entities.

Possible future approaches:
1. **Child ref syntax**: `@water_well/eos/0` — reference by parent ref + child role + index
2. **Prefab ref passthrough**: Prefabs declare their own refs that bubble up to the scene scope
3. **Scene-level children overrides**: Override specific children by index

This is deferred — top-level refs cover the immediate need.

## Impact

- **`jsonc_scene_bridge.zig`**: Add ref map, deferred component list, and resolution pass (~40-60 lines — smaller than originally estimated thanks to existing `Saveable` metadata)
- **No changes** to labelle-core, ECS, components, or runtime behavior
- **Fully backward compatible** — scenes without `"ref"` work identically
- **No performance impact** on scenes without refs

## Alternatives Considered

**Script-based setup**: A `"setup"` block in the scene that runs after entity creation. More powerful but requires a scripting layer in the scene format.

**Entity ID slots**: Reserve entity IDs in the scene file and use them directly. Fragile — IDs depend on creation order and ECS implementation.

**Pre-load hook**: A game script that runs before the scene loads to create entities. Works today but defeats the purpose of declarative scenes.
