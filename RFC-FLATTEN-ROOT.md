# RFC: Flatten the `root:` wrapper out of unified-format files

**Status:** Draft
**Author:** Alexandre
**Date:** 2026-05-26
**Bundled into:** v2.0.0 release (alongside engine#592 legacy-format removal)

## Problem

[RFC #560](./RFC-UNIFY-SCENES-AND-PREFABS.md) unified scenes and prefabs under a single shape where every file has a top-level `"root"` wrapper containing the entity definition. After six months of use, that wrapper is structural overhead that earns nothing — every file pays an extra indentation level for a key that conveys no information.

Real example from `flying-platform-labelle/prefabs/bandit_raid_enabled.jsonc`:

```jsonc
// today
{
    "root": {
        "components": {
            "BanditRaidEnabled": {}
        }
    }
}
```

Four lines and an indentation level to declare one component on one entity. FP has dozens of these "marker prefabs" — single-component, no children, pure tag. The `root:` wrapper is 50% of each file's byte count, and 100% of the keystrokes someone has to type before they can write what the file is actually about.

The same overhead shows up in scenes — every scene's entity list is one level deeper than it needs to be. And it accumulates: every reader's eye has to dismiss `root:` as boilerplate before it can read the actual content. Authoring tools have to indent everything one more time. Diff reviewers ignore the same key on every changed file.

## Why `root:` exists today

RFC #560's stated goal was that scenes and prefabs use the **same entity shape**. The wrapper was added as a docs/uniformity device — it gives the top-level entity an explicit name ("this is the scene's root entity" / "this is the prefab's root entity"). In code, the loader's `Value.getObject("root")` was a convenient unconditional entry point regardless of whether the file was a scene or a prefab.

The intent was correct. The implementation was over-engineered. The "name" the wrapper provides isn't queryable, isn't referenced anywhere else, and isn't surfaced in any tooling. It's purely a structural marker.

## Proposal

**Drop the `root:` wrapper.** Top-level keys of the file ARE the entity. Metadata keys (`name`, `version`) and entity-shape keys (`components`, `children`, `prefab`, `overrides`, `ref`) coexist at the same level. Scene composition via `include` remains a file-level scene key, not an entity key.

### Before / after — full coverage

**Component-only prefab:**

```jsonc
// today                                  // proposed
{                                          {
    "root": {                                  "components": {
        "components": {                            "BanditRaidEnabled": {}
            "BanditRaidEnabled": {}            }
        }                                  }
    }
}
```

**Prefab with children:**

```jsonc
// today                                            // proposed
{                                                    {
    "root": {                                            "components": {
        "components": {                                      "Workstation": { "kind": "bakery" }
            "Workstation": { "kind": "bakery" }          },
        },                                                   "children": [
        "children": [                                            { "prefab": "eis_slot" },
            { "prefab": "eis_slot" },                            { "prefab": "ios_slot" }
            { "prefab": "ios_slot" }                         ]
        ]                                                }
    }
}
```

**Prefab reference at root (specialization):**

```jsonc
// today                                            // proposed
{                                                    {
    "root": {                                            "prefab": "workstation_base",
        "prefab": "workstation_base",                    "overrides": {
        "overrides": {                                       "Workstation": { "kind": "bakery" }
            "Workstation": { "kind": "bakery" }          }
        }                                            }
    }
}
```

**Scene:**

```jsonc
// today                                            // proposed
{                                                    {
    "name": "main",                                      "name": "main",
    "root": {                                            "children": [
        "children": [                                        { "prefab": "background_sky" },
            { "prefab": "background_sky" },                  { "prefab": "ship_carcase" }
            { "prefab": "ship_carcase" }                 ]
        ]                                            }
    }
}
```

### Current loader key contract

The following table records the semantics implemented by the current JSONC
loader and resolver. It is intentionally narrower than the broader
flattening proposal: it documents where each key is valid rather than
inventing a second file shape.

| Scope | Key | Meaning |
|-------|-----|---------|
| Scene file top level | `include` | Array of scene-file paths. Each included scene is loaded recursively before the including scene's own entities. Include depth is bounded. |
| File-header `meta` | `include` | Reserved for a future consumer; currently unused. It does not cause inclusion. |
| Entity | `ref` | Structural name registered in the active `RefContext`. Scope depends on the traversal path, as described below; an explicit call-site `ref` on a nested instance is also exposed in its parent scope. |
| Component field | `@name` value | Consumer-side entity reference. On an `entity_ref` component field, `@name` is resolved in the resolver's second pass to the entity ID registered by `ref`. |

`ref` is an entity key, not a file key. In a flat prefab file the file object
*is* the prefab-root entity, so its top-level `ref` names that prefab-root
entity. The same key may appear on entries in `children` (and on entities
nested in entity-bearing component fields). A prefab reference can inherit
the prefab root's `ref` when the call-site entry does not provide its own.

For example, this prefab declares and consumes a name within the same scope:

```jsonc
// prefabs/storage.jsonc — the flat file object is the prefab-root entity
{
    "ref": "storage",
    "components": { "WithItem": { "item_id": "@item" } },
    "children": [
        { "ref": "item", "components": { "Item": {} } }
    ]
}
```

Reference scope depends on the traversal path, not just whether an entity
uses `prefab`:

- `processEntities` loads direct scene entries into the scene-file
  `RefContext`, including prefab references. Their root and inline descendant
  names share that scope; repeated names can collide.
- `loadChildEntity` creates a child context for a prefab nested under another
  entity. Inline children instead reuse the parent's context.
- `spawnAndLinkNestedEntities` creates a child context for an entity nested
  in an entity-bearing component field, including inline entities.

Child contexts chain to their parent for lookup, but their internal names
remain local. An explicit call-site `ref` on the nested instance is also
registered in the parent context. Thus two crate prefab instances nested
under another entity can each have an internal `handle` name without
colliding. This isolation does not apply if both crates are direct entries
in the scene's top-level `children` array.

Resolution has two passes per context: collect names and deferred fields,
then patch those fields. A nested context is patched as soon as that instance
finishes loading, before later top-level scene siblings have loaded. Its
lookups into enclosing scopes can therefore only find names already
registered there; a reference to a later sibling remains unresolved (the
loader logs it and leaves the field at zero). The scene context's own second
pass runs after all its direct entries load. References from an included
file belong to that file's separate context and are not visible to the
including scene.

### Mode-specific key sets are disjoint; `ref` is shared

The proposal works because the mode-specific top-level key sets are
well-defined and don't overlap. `ref` is a shared structural entity key,
outside those mode-specific sets:

| Group       | Keys                                                  |
|-------------|-------------------------------------------------------|
| Scene file metadata / composition | `name`, `version` *(future)*, `include` |
| Shared entity structure | `ref`                                                   |
| Entity-inline | `components`, `children`                              |
| Entity-ref  | `prefab`, `overrides`                                  |
| Legacy *(removed in v2.0)* | `entities`, `assets`                    |

A file's "is this a reference or inline?" classification is the same
predicate as today: does the entity object have `"prefab"`? For a flat prefab
file, that entity object is the top-level object and may also carry the shared
`ref` key.

### §B2 still applies

The "reference-mode entries cannot have children" rule (RFC #560 §B2, enforced engine-side in #586/#593) applies at the top-level just like it applies in `root.children`. A file shaped `{"prefab": "x", "children": [...]}` is still a load-time error.

### Loader changes

`src/jsonc/unified_format.zig` and `src/jsonc/scene_loader.zig` switch on `"root"` presence:

- **No `root` key** → top-level keys are the entity. Read `components` / `children` / `prefab` / `overrides` directly.
- **`root` key present** → legacy unified-format. Use today's code path.

During v1.x: both accepted, no warning. At v2.0: root-wrapped path removed alongside the other legacy paths.

(Rationale for no v1.x warning: this is a stylistic change, not a correctness one. Spamming deprecation warnings during a normal release would be annoying. The migrator handles the cleanup; the audit detects it.)

### Audit + migrator

`labelle audit unification` (cli#232, extended in cli#236) gets a fourth legacy finding type:

```
[unified-format] redundant "root" wrapper: lift its contents to the file's top level (RFC #560 phase 2)
```

A new `labelle migrate unified` subcommand (or `--fix` mode on the audit) performs the mechanical transform: parse, lift, write back with comment preservation (Strategy B byte-offset edits, same as today's earlier migration in FP).

## Sequence with v2.0

| Step | When | What |
|------|------|------|
| 1 | v1.47.0 (or next minor) | Loader accepts both forms. Audit detects legacy root wrapper. |
| 2 | v1.47.x | `labelle migrate unified` ships. Projects can clean up at their own pace. |
| 3 | v2.0.0 | Loader drops root-wrapped path. Also drops legacy `entities` / `components-on-ref` / `assets` / `.initial_scene`. Single breaking bump. |

Step 1 is the smallest engine PR — add the no-root branch in the loader, audit walker extension, no warnings. Step 2 is the migrator (could be the same PR, or a follow-up). Step 3 deletes code.

## Open questions

1. **Tooling acceptance criteria for v2.0**: should we gate the v2.0 ship on "all toolkit-managed projects (bouncing-ball, every assembler example, FP) run cleanly through `labelle audit unification` with the new detection enabled"? Today's audit on the same set surfaced drift the migration agents missed; same gating policy seems wise.

2. **`labelle init` template hygiene**: today's `labelle init` emits the root-wrapped shape. If we ship step 1 in v1.47, should the generator immediately emit flat form (silent style preference) or keep emitting root-wrapped until v2.0 (status quo for migration runway)? I lean toward switching the generator immediately — new projects get the better shape from day one, the audit can still detect the old shape for projects that were generated earlier.

3. **Bundle scope**: is there other silent renaming or deprecated-but-still-accepted surface we should fold into the v2.0 bump while it's open? Worth a focused sweep before committing.

4. **`name` field positioning**: in the flat form, `name` is a top-level metadata key sitting alongside `components`/`children`. Should we make the order canonical (metadata first, then entity-shape) and have the audit warn on out-of-order files? My instinct is no — JSON object order doesn't matter for the loader, and forcing it adds review friction for negligible gain.

5. **What about `.initial_prefab` in `project.labelle`?** Unaffected — that's a `project.labelle` field, not an entity-tree file. Unchanged by this RFC. (Legacy `.initial_scene` removal is in engine#592 phase 1 work.)

## Non-goals

- Schema validation / `.labelle.schema.json` — separate concern, not part of this RFC.
- Per-entity metadata fields (`tags`, `id`, etc.) — orthogonal.
- Versioned scene/prefab format — that would deserve its own RFC if pursued.
- Changes to `project.labelle` structure — unchanged.

## Related

- [RFC #560](./RFC-UNIFY-SCENES-AND-PREFABS.md) — unified scene/prefab format (phase 1)
- engine#592 — legacy unified-format removal (bundles with this RFC into v2.0)
- engine#586 / engine#593 — §B2 enforcement (prerequisite, already landed)
- cli#232 — `labelle audit unification` command
- cli#236 — audit extension for legacy unified-format detection (this RFC's audit extension follows the same shape)
