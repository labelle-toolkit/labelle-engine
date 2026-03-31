# RFC: Scene Entity Cross-References

**Issue:** #413
**Status:** Draft

## Problem

Scene files cannot express relationships between entities. Components like `Stored` and `WithItem` require entity IDs that are only known at runtime. This means:

- Test scenes can't pre-populate storages with items
- Any entity-to-entity relationship must be set up by scripts at runtime
- Scene files can only describe isolated entities, not connected state

## Design

### Ref Declaration

Any entity in a scene file can declare a `"ref"` name:

```jsonc
{ "ref": "eos1", "prefab": "eos", "components": { "Position": { "x": -55, "y": 0 } } }
```

Refs are scene-scoped string identifiers. They don't affect the entity at runtime — they're only used during scene loading for cross-reference resolution.

### Cross-Reference Syntax

Component fields that hold entity IDs can use `@name` to reference another entity:

```jsonc
{ "ref": "water1", "prefab": "water", "components": {
    "Stored": { "storage_id": "@eos1" }
}}
```

The `@eos1` string is resolved to the actual `u64` entity ID of the entity with `"ref": "eos1"` during scene loading.

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

The current single-pass loader creates and configures entities in one sweep. Cross-references require two passes:

**Pass 1 — Create and collect refs:**
- Iterate all entities in the scene
- Create each entity and apply non-ref components (Position, Shape, etc.)
- If entity has `"ref"`, store `ref_name -> entity_id` in a hash map

**Pass 2 — Resolve refs:**
- Iterate entities that had `@ref` values in their components
- Look up each `@name` in the ref map
- Replace with the resolved `u64` entity ID
- Apply the resolved component via `addComponent`

Components with `@ref` fields are deferred to pass 2. Components without refs are applied immediately in pass 1 (no behavior change for existing scenes).

### Detection

A component value contains a ref if it's a string starting with `@`. The scene bridge already knows which fields are entity refs via the `Saveable` declaration's `.entity_refs` list. Only those fields need ref resolution.

```zig
// In Saveable declaration:
pub const save = Saveable(.saveable, @This(), .{
    .entity_refs = &.{"storage_id"},  // <-- these fields can hold @refs
});
```

### Implementation Scope

**In scope (this RFC):**
- `"ref"` on top-level scene entities
- `@name` resolution in component fields listed in `.entity_refs`
- Two-pass loading in `jsonc_scene_bridge.zig`
- Forward and backward references (entity order doesn't matter)

**Out of scope (future work):**
- Refs on nested children (workstation storage children)
- Refs in prefab files
- Path-based refs (`@water_well.eos.0`)
- Refs in `spawnPrefab` at runtime

### Nested Children

Workstation storages (EOS, EIS, etc.) are nested children defined inside prefab files. They can't be referenced directly from the scene because they don't appear as top-level entities.

Possible future approaches:
1. **Child ref syntax**: `@water_well/eos/0` — reference by parent ref + child role + index
2. **Prefab ref passthrough**: Prefabs declare their own refs that bubble up to the scene scope
3. **Scene-level children overrides**: Override specific children by index in the scene entity

This is deferred — top-level refs cover the immediate need (test scenes with pre-populated state).

## Impact

- `jsonc_scene_bridge.zig`: Add ref collection and resolution passes (~60-80 lines)
- No changes to ECS, components, or runtime behavior
- Fully backward compatible — scenes without `"ref"` work identically
- No performance impact on scenes without refs (single-pass path unchanged)

## Alternatives Considered

**Script-based setup**: A `"setup"` block in the scene that runs after entity creation. More powerful but requires a scripting layer in the scene format.

**Entity ID slots**: Reserve entity IDs in the scene file and use them directly. Fragile — IDs depend on creation order and ECS implementation.

**Pre-load hook**: A game script that runs before the scene loads to create entities. Works today but defeats the purpose of declarative scenes.
