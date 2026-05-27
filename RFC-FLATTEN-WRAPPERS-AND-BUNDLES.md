# RFC: Flatten unified-format wrappers and add bundle shape

**Status:** Draft
**Author:** Alexandre
**Date:** 2026-05-27
**Builds on:** [RFC-FLATTEN-ROOT](./RFC-FLATTEN-ROOT.md) (#594) and [RFC-UNIFY-SCENES-AND-PREFABS](./RFC-UNIFY-SCENES-AND-PREFABS.md) (#560)
**Bundled into:** v2.0.0 release alongside #594 and engine#592

## Problem

After RFC #594 drops the `root:` wrapper, the unified-format files still carry significant structural noise. Looking at the dominant pattern across `flying-platform-labelle`'s 90 scene + prefab files post-RFC-#594:

```jsonc
{ "prefab": "rabbit", "overrides": { "Position": { "x": 400, "y": 0 } } }
```

Five levels of nesting (`{... overrides {Position {x, y}}}`) for what is logically "place rabbit at (400, 0)". The `overrides` and `components` wrappers, plus the explicit `children:` array for the bundle case, all add nesting layers that earn nothing structurally — they're disambiguators for things that the file's content already implies.

The colony scene illustrates the bundle pain: ~50 sibling entities under `children:`, each with the same `prefab/overrides/Position` shape. The outer wrapping object exists only to attach a `children:` key to it; there's no actual root entity.

## Proposal

Four independent axes that together collapse the format to its semantic essentials. Axis 1 already lives in RFC #594; this RFC adds axes 2-4.

### Axis 1 — Drop `root:` wrapper (already in RFC #594)

Top-level keys are the entity directly. Listed here for completeness; the design is in #594.

### Axis 2 — Drop `overrides:` and `components:` wrappers via case convention

Today's structural keys are lowercase (`prefab`, `children`, `name`, `overrides`, `components`); component keys are PascalCase (`Position`, `BuildIntent`, `Workstation`, etc.). The naming convention already disambiguates them visually — promote it to a parser rule.

**Rule:** within an entity object, lowercase keys are structural; PascalCase keys are component overrides (for prefab references) or component declarations (for inline entities).

```jsonc
// reference + overrides (today, post-#594)
{ "prefab": "rabbit", "overrides": { "Position": { "x": 400, "y": 0 } } }
// reference, flattened (proposal)
{ "prefab": "rabbit", "Position": { "x": 400, "y": 0 } }

// inline (today, post-#594)
{ "components": { "BuildIntent": { "room_type": "stair_room", "c": 4, "f": 1 } } }
// inline, flattened (proposal)
{ "BuildIntent": { "room_type": "stair_room", "c": 4, "f": 1 } }
```

`overrides` and `components` both disappear. The mode (inline vs reference) is determined by whether `prefab` is present — same as today, just minus one wrapping layer per entry. §B2 (no `children` on a reference) applies identically.

### Axis 3 — File-as-array for bundles (drop file-level `children:`)

When a file has no real root entity — when it's just a list of sibling entities with no Parent relationship between them — represent it as a top-level JSON array. No outer object, no `children:` key, no implicit root.

**Rule:** if the file's top-level JSON value is an Array, every element is an independent sibling entity. If it's an Object, it's a single root entity (with optional `children:` for actual children-of-it).

```jsonc
// scene today (post-#594): wrapping object exists only to carry "children:"
{
    "name": "colony",
    "children": [
        { "prefab": "ship_carcase", "Position": { "x": 0,   "y": 0 } },
        { "prefab": "ship_carcase", "Position": { "x": 780, "y": 0 } }
    ]
}

// scene, bundle-direct (proposal — combined with Axis 2)
[
    { "prefab": "ship_carcase", "Position": { "x": 0,   "y": 0 } },
    { "prefab": "ship_carcase", "Position": { "x": 780, "y": 0 } }
]
```

Scenes become indistinguishable from bundle-shaped prefabs — they're just bundle-prefabs you happen to load directly. Reusable composition of bundle prefabs falls out for free (RFC follow-up: a scene can reference a bundle prefab the same way it references a single-entity prefab).

`children:` stays valid INSIDE entity objects when there's a true Parent-of-children relationship:

```jsonc
[
    { "prefab": "ship_carcase", "Position": { "x": 0, "y": 0 } },
    {
        "Workstation": { "kind": "kitchen" },
        "Image": { "sprite": "kitchen" },
        "Position": { "x": 156, "y": 93 },
        "children": [
            { "prefab": "eis_slot", "Position": { "x": -30, "y": 0 } },
            { "prefab": "ios_slot", "Position": { "x":  30, "y": 0 } }
        ]
    },
    { "prefab": "worker", "Position": { "x": 0, "y": 0 } }
]
```

Three sibling top-level entities; the middle one has its own children-of-it via the existing key.

### Axis 4 — `meta:` field for authoring-only side data

Add a `meta:` structural key for free-form documentation/tooling data that the engine never reads at runtime. Useful for tooltips, editor labels, build-tool tags, debug hints — anything that exists to help humans or tools and isn't needed by gameplay.

```jsonc
[
    { "prefab": "kitchen", "Position": { "x": 0, "y": 93 }, "meta": { "label": "main kitchen" } },
    { "prefab": "kitchen", "Position": { "x": 156, "y": 93 }, "meta": { "label": "secondary kitchen" } }
]
```

**Rules:**
- **Authoring-only:** the engine strips `meta:` at load. Never reaches gameplay code. If your game needs the data at runtime, model it as a component instead.
- **No propagation:** `meta:` is local to the entry it sits on. A scene reference's meta does NOT merge with the referenced prefab's file-level meta. Each is its own bag.
- **No schema:** arbitrary JSON nesting/types/keys. The loader doesn't validate contents.
- **Tools-visible:** the audit, the editor, and any future linter can read `meta:` blocks. They're authoritative for tooling-side decisions.

### Closed key set (final after all axes)

Within any entity:

| Group | Keys |
|---|---|
| Structural (lowercase) | `prefab`, `children`, `meta` |
| Components (PascalCase) | any component type, depth-arbitrary value shape |

File top-level:

| Shape | Means |
|---|---|
| `[ ... ]` | Bundle: each element a sibling entity, no implicit root |
| `{ ... }` | Single root entity (optionally with `children:`) |

`name` drops as an entity-level field — file basename is the identifier (already the prefab convention; extends to scenes).

## Before / after on real FP scenes

### Colony scene — simplest possible shape

```jsonc
// today (post-#594)
{
    "name": "colony",
    "children": [
        { "prefab": "ship_carcase", "overrides": { "Position": { "x": 0,   "y": 0 } } },
        { "prefab": "ship_carcase", "overrides": { "Position": { "x": 780, "y": 0 } } },
        { "prefab": "condenser",    "overrides": { "Position": { "x": 0,   "y": 0 } } }
    ]
}

// after this RFC
[
    { "prefab": "ship_carcase", "Position": { "x": 0,   "y": 0 } },
    { "prefab": "ship_carcase", "Position": { "x": 780, "y": 0 } },
    { "prefab": "condenser",    "Position": { "x": 0,   "y": 0 } }
]
```

Byte count drops ~40% across the scene's 50-entry file.

### Inline build-intent marker

```jsonc
// today (post-#594)
{ "components": { "BuildIntent": { "room_type": "stair_room", "c": 4, "f": 1 } } }

// after this RFC
{ "BuildIntent": { "room_type": "stair_room", "c": 4, "f": 1 } }
```

### Workstation prefab with slots (entity-with-children)

```jsonc
// today (post-#594)
{
    "components": {
        "Workstation": { "kind": "kitchen" },
        "Image": { "sprite": "kitchen" }
    },
    "children": [
        { "prefab": "eis_slot", "overrides": { "Position": { "x": -30, "y": 0 } } }
    ]
}

// after this RFC
{
    "Workstation": { "kind": "kitchen" },
    "Image": { "sprite": "kitchen" },
    "children": [
        { "prefab": "eis_slot", "Position": { "x": -30, "y": 0 } }
    ]
}
```

## Migration

Mechanical, idempotent transforms — same shape as `labelle migrate unified` already handles for the legacy patterns. Four new transforms:

1. **Lift `overrides` block:** `{prefab, overrides: {X, Y}}` → `{prefab, X, Y}`. PascalCase keys at the entry level.
2. **Lift `components` block:** `{components: {X, Y}, ...}` → `{X, Y, ...}`. Same shape.
3. **File-as-array for no-root scenes/prefabs:** when the file's top-level is `{name?, children: [...]}` with no entity-shape keys (no `prefab`, no PascalCase), collapse to array `[...]`. The `name:` field drops; filename becomes the identifier.
4. **`name:` to filename:** the loader's effective-name rule already handles this (filename is the default identifier). Migrator drops the `name:` field unless it diverges from the filename.

All four are byte-offset positional edits with comment preservation (same Strategy B the existing migrator uses).

The audit gains four new finding types:

- `legacy_overrides_wrapper`
- `legacy_components_wrapper`
- `legacy_file_object_no_root` (file is `{name?, children}` with no entity-shape — should be array)
- `legacy_redundant_name_field` (file declares `name:` that matches the filename — can drop)

## Sequence with v2.0

This RFC bundles into the same v2.0 release as #594 and engine#592 (legacy unified-format removal). The migrator handles all transforms in one pass; the loader's dual-accept matrix grows but stays tractable during v1.x.

| Step | When | What |
|------|------|------|
| 1 | v1.48.0 (or next minor after #594 ships) | Loader accepts both forms (root-wrapped/flat AND wrapped/flat-components AND object/array). Audit detects all four new legacy patterns. Migrator transforms them. |
| 2 | v1.48.x | Projects clean up via migrator at their own pace. |
| 3 | v2.0.0 | Loader drops the legacy paths (root wrapper, overrides/components wrappers, file-as-object-with-only-children). |

`labelle init` scaffolds in the new shape from day one (step-1 PR), so new projects start clean.

## Open questions

1. **Does the `name:` field still have a use?** Today it lets a file claim an identifier different from its basename. Under this RFC, file identity = basename, full stop. Cases where the override is useful:
   - Two folders contain `main.jsonc` — basename collision, today disambiguated by name fields. After the RFC: hard collision, or use folder-prefixed identifiers (`debug/main`, `colony/main`)?
   - Friendly display names for tools. Could move into `meta: { "label": "..." }`.

   My read: drop `name:` entirely. Folder prefix handles collisions; display labels go in meta.

2. **What about the empty-bundle case?** An empty array `[]` is a valid bundle of zero entities. Useful? Or should empty bundles be rejected as probably-a-mistake?

3. **§B2 enforcement on bundle reference**. A bundle prefab CAN be referenced from a scene by name: `{ "prefab": "colony_layout" }`. Per §B2, that reference can't have `children:` — but does it inherit-meta or override-meta from the bundle's file-level meta? Per Axis 4's "no propagation" rule, no. Each bag is local. Confirmed in the RFC body.

4. **Scene `name:` interaction with the `--scene` CLI flag.** `labelle run --scene=colony` resolves "colony" to a scene file. Today: matches the scene's `name:` field OR the file basename. After dropping `name:`: only matches the file basename. Behaviorally compatible for any project where `name:` matches basename (the conventional case).

5. **Component name validation.** Today the loader doesn't validate that a PascalCase top-level key is a registered component type — it just attempts the override and fails late. After dropping the `overrides:` wrapper, any unknown PascalCase key is silently treated as an override of a nonexistent component, which deep-merge will accept and ignore. Worth tightening: the loader could reject unknown-component overrides at parse time (a 1-line check against the registered component registry).

## Non-goals

- Vector-shape array shorthand for `Position` etc. (`{x, y}` stays object form per user preference).
- Comment-syntax extensions beyond JSONC's existing `//` and `/* */`.
- Multi-line strings, includes, templating, or any expansion of expressive power. This RFC reduces structural noise; it does not add capability.
- Per-entity unique IDs / cross-entity references. Sibling references in bundles are positional only.

## Related

- [RFC #560](./RFC-UNIFY-SCENES-AND-PREFABS.md) — unified scene/prefab format (phase 1)
- [RFC #594 / `RFC-FLATTEN-ROOT.md`](./RFC-FLATTEN-ROOT.md) — drop the `root:` wrapper (phase 2)
- engine#592 — legacy unified-format removal (v2.0 epic)
- engine#586 / engine#593 — §B2 enforcement (loader-side rejection of `{prefab + children}`)
- cli#232 — `labelle audit unification` command (foundation for the new audit findings)
- cli#238 — `labelle migrate unified` (foundation for the new migrator transforms)
