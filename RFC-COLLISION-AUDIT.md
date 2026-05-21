# RFC #560 — `scenes/` / `prefabs/` Name-Collision Audit (Issue #570)

**Date:** 2026-05-21
**Branch:** `feat/570-collision-audit` (off `origin/feat/unify-scenes-prefabs`)
**Scope:** Audit every in-tree project for effective-name collisions across `scenes/`
and `prefabs/` before #561 merges both directories into one flat name-keyed registry.

## Method

RFC #560 introduces a flat, name-keyed registry. Every `.jsonc` file under a project's
`scenes/` and `prefabs/` directories resolves by an **effective name**:

- the top-level JSON `"name"` string field if present, otherwise
- the filename basename without the `.jsonc` extension.

A **collision** is two `.jsonc` files within the *same project* that resolve to the
same effective name. After #561, `scenes/` and `prefabs/` are scanned into one
registry, so a scene and a prefab resolving to the same name is a **cross-directory
collision** — the case #570 specifically warns about.

Every `.jsonc` file under each project's `scenes/` and `prefabs/` (including nested
subfolders) was recursively listed and JSONC-parsed (comments and trailing commas
stripped) to extract the effective name. Generated `.labelle/` build-output
directories were excluded — they are build artifacts, copies of the source trees.

## Per-Project Inventory

| Project | `scenes/` `.jsonc` | `prefabs/` `.jsonc` | Notes |
|---|---:|---:|---|
| `flying-platform-labelle` | 36 | 54 | All `.jsonc`. Only project materially affected. |
| `labelle-cli/test/plugin-manifest-test` | 1 | 0 | `scenes/main.jsonc` only; no `prefabs/`. |
| `labelle-cli/test/imgui-anchor-test` | 1 | 0 | `scenes/main.jsonc` only; no `prefabs/`. |
| `labelle-cli/test/nuklear-plugin-test` | 1 | 0 (empty) | `scenes/main.jsonc`; `prefabs/` exists but empty. |
| `labelle-cli/test/gui-plugin-test` | 1 | 0 (empty) | `scenes/main.jsonc`; `prefabs/` exists but empty. |
| `bouncing-ball` | 0 | 0 | Uses legacy `scenes/main.zon` — not `.jsonc`. |
| `labelle-gui/examples/project_1` | 0 | 0 | Uses legacy `scenes/main.zon`; `prefabs/` empty (`.gitkeep`). |
| `labelle-cli/examples/raylib_carry_test` | 0 | 0 | `prefabs/` source dir empty (only `.labelle/` generated). |
| `labelle-cli/examples/raylib` | 0 | 0 | Only `.labelle/` generated dirs, no source `.jsonc`. |
| `bakery-game` | 0 | 0 | Cloned read-only; uses legacy `.zon` (see below). |

**Total `.jsonc` files audited: 94** (90 in `flying-platform-labelle`,
4 single-scene `labelle-cli` test fixtures).

### `flying-platform-labelle` detail

- `scenes/` — 5 top-level (`save_load_smoke`, `colony`, `loading`, `menu`, `main`),
  16 under `scenes/debug/`, 15 under `scenes/debug/bandit/`. All carry an explicit
  `"name"` field equal to their basename.
- `prefabs/` — 54 files across `background/`, `carcase/`, `characters/`, `furniture/`,
  `items/`, `rooms/`, `storage/`, `workstations/`. None carry a `"name"` field;
  all resolve by basename.

### `bakery-game` (cloned read-only to `/tmp/bakery-game-audit`)

Clone succeeded. `scenes/main.zon` and 6 prefabs (`baker`, `bread`, `flour`, `oven`,
`water`, `water_well`) — **all `.zon`**, not `.jsonc`. Not scanned by the `.jsonc`
registry, so it cannot collide under #561. (It will need format migration separately
under RFC #560, but that is out of scope for this collision audit.)

## Collisions Found

**None.**

- No within-`scenes/` collisions in any project.
- No within-`prefabs/` collisions in any project.
- No scene-vs-prefab cross-directory collisions in any project.

Every effective name in `flying-platform-labelle` is unique across the combined
`scenes/` + `prefabs/` namespace. Each `labelle-cli` test fixture has a single
`scenes/main.jsonc` and an empty or absent `prefabs/`, so collisions are impossible.
The `main` name appears once per project but never twice within one project.

## Verdict

**Safe.** It is safe to enable the unified registry's hard collision error as part of
#561. No file needs to be renamed and no `"name"` field needs to be added or changed
in any in-tree project. The merged `scenes/` + `prefabs/` scan will not land red.

Acceptance criteria of #570 are met:
- Zero basename/effective-name collisions across `scenes/` + `prefabs/` in every
  in-tree project.
- #561 can merge without breaking any project's load.

### Caveats / follow-ups (not collisions, out of #570 scope)

- `bouncing-ball`, `labelle-gui/examples/project_1`, and `bakery-game` still use the
  legacy `.zon` scene/prefab format. They are invisible to the `.jsonc` registry scan,
  so they pose no collision risk for #561, but they require the format migration
  tracked elsewhere under RFC #560.
- All 54 `flying-platform-labelle` prefabs resolve by basename only (no `"name"`
  field). They are currently collision-free, but adding `"name"` fields later — or
  introducing new files — should preserve uniqueness across the combined namespace.
