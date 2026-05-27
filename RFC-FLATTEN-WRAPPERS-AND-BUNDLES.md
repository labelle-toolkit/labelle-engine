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

Add a `meta:` structural key for free-form documentation/tooling data that the engine never reads at runtime. Tooltips, editor labels, build-tool tags, debug hints, friendly display names — anything that exists to help humans or tools and isn't needed by gameplay.

Including **friendly display labels via `meta.name`**:

```jsonc
[
    { "prefab": "kitchen", "Position": { "x": 0,   "y": 93 }, "meta": { "name": "Main Kitchen" } },
    { "prefab": "kitchen", "Position": { "x": 156, "y": 93 }, "meta": { "name": "Secondary Kitchen" } }
]
```

The file's own friendly label (at the bundle header) also lives in `meta`:

```jsonc
// scenes/colony.jsonc
[
    { "meta": { "name": "Production Colony Demo", "author": "alexandre" } },
    { "prefab": "ship_carcase", "Position": { "x": 0, "y": 0 } },
    ...
]
```

This collapses what used to be a separate top-level `name:` key into `meta`. The structural surface stays minimal — three keys total at entity scope (`prefab`, `children`, `meta`).

**Rules:**
- **Authoring-only:** the engine strips `meta:` at load. Never reaches gameplay code. If your game needs the data at runtime, model it as a component instead.
- **No propagation:** `meta:` is local to the entry it sits on. A scene reference's meta does NOT merge with the referenced prefab's file-level meta. Each is its own bag.
- **No schema:** arbitrary JSON nesting/types/keys. The loader doesn't validate contents.
- **Tools-visible:** the audit, the editor, and any future linter can read `meta:` blocks. They're authoritative for tooling-side decisions.
- **Identity vs label:** the file basename is the identifier (used by `{prefab: "..."}` references, `--scene=` CLI flag, audit collision checks). `meta.name` is a free-form display label, doesn't need to be unique, never affects resolution.

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

`name` drops as a top-level structural key. **Identity** comes from the file basename (already the prefab convention; extends to scenes). **Friendly display labels** live in `meta.name` — see Axis 4. Three structural keys total at entity scope, one (`meta`) at file-header scope. Anything not gameplay-relevant goes in `meta`; the rule has no exceptions.

### Unknown component handling

PascalCase keys are interpreted as components. The loader cross-checks each PascalCase key against the registered component registry:

- **Known component** — applied normally.
- **Unknown component** — **warn-once** at load with file/line, but proceed. Audit promotes the warning to a finding. Lets you author a prefab against a plugin that hasn't loaded yet (forward-compat) without silently swallowing typos like `Posiiton`.

Rationale over the strict-error alternative: write-the-prefab-before-plugin-lands is a legitimate workflow (cross-repo prefab authoring, plugin order during init); breaking it at parse time hurts more than the typo it catches. v2.0+ may promote unknown-component to a strict error if the ecosystem warn-rate stays low — out of scope for this RFC.

### Empty bundles

`[]` at file top level is a valid zero-entity bundle. No warning. Authoring workflows benefit (new file → `[]` → add entities), and the "empty file checked in by mistake" case is symmetric to other half-written files (a prefab with only `{ "Position": {...} }` is similarly partial) which the loader also accepts. Tooling layers may add diagnostics; the format itself stays permissive.

Object shape `{}` (empty entity, no `prefab` / no components / no `children`) stays rejected — an entity with no content is malformed regardless of array vs object file shape.

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
3. **File-as-array for no-root scenes/prefabs:** when the file's top-level is `{name?, children: [...]}` with no entity-shape keys (no `prefab`, no PascalCase), collapse to array `[...]`. If the wrapping object had a `name:` field, transform 4 handles it (it lands on the bundle header as `{meta: {name: "..."}}` or drops if redundant).
4. **`name:` → `meta.name` or drop:** the loader's identity rule is now "basename always wins."
   - `name:` matches basename → **drop** (redundant).
   - `name:` differs from basename → **move into `meta.name`** as a friendly label. If `meta:` already exists, merge `name` into it. **Flag for human review** any case where other files reference this one via `{prefab: "<declared-name>"}` — those references must update to use the basename, OR the file should be renamed to match the declared name. The audit's cross-reference check catches these.

All four are byte-offset positional edits with comment preservation (same Strategy B the existing migrator uses).

The audit gains four new finding types:

- `legacy_overrides_wrapper`
- `legacy_components_wrapper`
- `legacy_file_object_no_root` (file is `{name?, children}` with no entity-shape — should be array)
- `legacy_name_field` (any top-level `name:` field — must move to `meta.name` if differs from basename, or drop if redundant)

Plus a 5th warn-only diagnostic (per Q5 resolution):

- `unknown_component` — PascalCase key on an entity that doesn't match any registered component. Warn at load, surfaced by audit as a finding.

## Sequence with v2.0

This RFC bundles into the same v2.0 release as #594 and engine#592 (legacy unified-format removal). The migrator handles all transforms in one pass; the loader's dual-accept matrix grows but stays tractable during v1.x.

| Step | When | What |
|------|------|------|
| 1 | v1.48.0 (or next minor after #594 ships) | Loader accepts both forms (root-wrapped/flat AND wrapped/flat-components AND object/array). Audit detects all four new legacy patterns. Migrator transforms them. |
| 2 | v1.48.x | Projects clean up via migrator at their own pace. |
| 3 | v2.0.0 | Loader drops the legacy paths (root wrapper, overrides/components wrappers, file-as-object-with-only-children). |

`labelle init` scaffolds in the new shape from day one (step-1 PR), so new projects start clean.

## Resolved decisions (originally open questions)

All five resolved during RFC discussion:

1. ✅ **`name:` drops as a structural key.** Identity = filename basename, full stop. Friendly display labels live in `meta.name` instead. Folder-prefixed identifiers handle basename collisions across folders (`debug/main`, `colony/main`). Audit detects + migrator handles the few "name differs from basename" cases (move to meta unless cross-references force a rename).

2. ✅ **Empty bundles `[]` are valid.** Loader accepts silently. Authoring workflows benefit; tooling layers can add diagnostics. Object-shape `{}` (empty entity) stays rejected — symmetric with other malformed entity shapes.

3. ✅ **§B2 + bundle references — no propagation.** A bundle prefab's file-level `meta` does NOT merge into scenes that reference it. Each `meta` bag is local to its entry. Already codified in Axis 4's rules.

4. ✅ **`--scene=` CLI flag matches basename only.** Behaviorally compatible for any project where `name:` matched basename today (the conventional case). The migrator's transform 4 handles the rare divergent case.

5. ✅ **Unknown PascalCase keys → warn, don't error.** Forward-compat with cross-repo plugin authoring; typos like `Posiiton` still surface visibly. Audit promotes warning to a finding. v2.0+ may promote to strict if ecosystem warn-rate stays low.

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
