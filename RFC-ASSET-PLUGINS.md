# RFC: Asset Plugins — full plugins with sprites, atlases, and packs included

**Issue:** labelle-toolkit/labelle-engine#725  
**Status:** Draft  
**Author:** Alexandre  
**Date:** 2026-07-10 (rev 2 — the plugin is the attachable unit; plugins can bundle packs; rev 3 — studio panels: plugin-contributed editor UX)

## Problem

A labelle game can attach a **plugin** — one `project.labelle` entry, version-pinned — and get code: systems, controllers, hooks (pathfinding, fsm, imgui). A game can also organize content into **packs** — per-domain bundles of prefabs/scripts/components, namespaced `pack__*`. But neither unit can ship **assets**: the sprites, atlases, and tilesets the content draws.

The consequence is a hidden contract. Flying-Platform's `sky` pack renders backdrops and clouds — and its prefabs carry a warning comment that the assembler *"expects the `background` + `cloud` atlases in the scene meta"*: the **game** must hand-declare, in its own `.resources`, atlases whose frame names happen to match what the pack references. Nothing checks it. A missing atlas or a misspelled frame is a **silent runtime blank**.

And it blocks the real product this RFC targets: **full plugins that attach to a game with the assets already on them.** A vendor should be able to build "fantasy dungeon" — tileset atlases, prop prefabs, a map-generator script, organized as packs inside one plugin, plus the generator's controls as a **studio panel** — sell it as a version-pinned repo, and a buyer should get a working install (editor tab included) from one `project.labelle` line, validated at generate time.

### The unit model: plugins carry, packs organize

- A **plugin** is the *attachable unit* — the repo+version a game pins. It may contain: code (as today), **assets** (this RFC), **packs** (this RFC — a plugin can bundle whole packs inside it), and **studio panels** (this RFC — declarative editor UX, e.g. a generator's controls).
- A **pack** is the *content-organization unit* — prefabs/scripts/components/assets for one domain. Packs live in the game tree (`packs/`, as today) **or inside a plugin** (`<plugin>/packs/<name>/`), with identical structure either way.
- Assets attach at **both levels**: plugin-level `assets/` (for the plugin's own visuals) and pack-level `assets/` (for a pack's content), flowing through one merge.

The authoring path stays smooth: prototype content as a game-local pack → group packs into a plugin repo → publish/sell the plugin. No restructuring at any step.

## Verified current architecture (investigation, 2026-07-10)

The pipeline end to end, with the seams this RFC builds on:

- **Authoring → atlas.** `labelle pack <dir>` (MaxRects, `labelle-cli/src/cli/pack.zig:22-86`, `src/texpack/`) or free-tex-packer (`.ftpp`, FP's choice) → a `<name>.png` sheet + `<name>.json` in **TexturePacker JSON-hash** format: `frames{ name → frame{x,y,w,h}, rotated, trimmed, spriteSourceSize, sourceSize, pivot }` + `meta{image,size}`. Both packers emit the same schema — the consumer is packer-agnostic.
- **Game-side declaration.** `project.labelle` `.resources = .{ .{ .name, .json, .texture, .lazy }, … }` (`ResourceDef`, also `sound`/`font` variants — `labelle-cli/src/cli/project_config.zig:130-150`). Scenes preload by name: `{"meta": {"assets": ["background", …]}}` → codegen'd `SceneAssetManifests` (`labelle-assembler/src/codegen/blocks/scene_manifests.zig:37-99`).
- **Codegen.** `resource_loader.zig:52-112` emits, per resource, eager `g.loadAtlasFromMemory(name, @embedFile(json), @embedFile(png), ".png")` or lazy `registerAtlasFromMemory(...)`. `asset_wiring.zig:49-160` carries the **compressed-texture seam** (ASTC: `isCompressed`/`uploadCompressed` gates, engine#450). The lazy path feeds the **streaming catalog** (`labelle-engine/src/assets/catalog.zig` — RFC-ASSET-STREAMING).
- **Runtime lookup is global and un-namespaced.** `game.findSprite(name)` searches **every loaded atlas** by frame name. Prefab/event/component keys are `pack__`-prefixed at copy time; **sprite frame names are not**. Two atlases sharing a frame name = undefined winner; a missing atlas = silent blank.
- **Plugins and packs already share one declaration + copy machinery.** Both are entries in `project.labelle`'s `.plugins` list (`.repo = "github.com/…"` + `.version` for published plugins; `@packs/<name>` / `@libs/<name>` / `local:` for in-tree). `plugin.labelle` declares convention dirs with modes `copy_and_scan` / `copy_only` / **`ship_from_plugin`** (`plugin_manifest.zig:74-93`) — plugin-shipped *content* partially exists. `assets/` is a **reserved convention dir that is already copied** from packs (`root.zig:530-632`) — but nothing registers the copied files. Pack-shipped art is dead weight today.
- **What does NOT exist:** resource registration from plugins or packs; sprite-name namespacing; asset validation; and **nested packs** — nothing discovers `packs/` inside a plugin repo.
- **Tilesets are just atlases.** Tiles are ordinary `Position`+`Sprite` entities (labelle-studio-tmx RFC-tilemap). A "map generator" is ordinary plugin/pack *scripts* spawning tile entities — the code half ships today; only the art half is missing.
- **Distribution already works.** Git-tag fetch into the package cache, `labelle.lock` pinning, private repos via git credentials.

**The key architectural fact:** the extension point is the assembler's **resource merge**. If plugins and packs contribute `ResourceDef` entries into the same list the game's `.resources` feeds, everything downstream — embed, ASTC, lazy streaming, scene manifests — works unchanged. The runtime never needs to know where an atlas came from.

## Proposal

Plugins (and the packs inside them, and game-local packs) declare the atlases they ship; the assembler merges them into the game's resource catalog **namespaced**, rewrites the owning unit's sprite references to match, and validates every reference at generate time.

### Plugin layout: the full unit

```text
fantasy-dungeon/                  # the plugin repo — the attachable unit
  plugin.labelle
  src/ …                          # optional plugin code, as today
  assets/                         # plugin-level assets
    ui_icons.png
    ui_icons.json
  packs/                          # packs bundled INSIDE the plugin
    dungeon/
      pack.labelle
      assets/
        tiles.png                 # prebuilt atlas sheet (packed, not raw art)
        tiles.json                # TexturePacker JSON-hash
      prefabs/ …                  # reference "wall_stone.png" from tiles
      scripts/ …                  # e.g. the dungeon generator
    props/
      pack.labelle
      assets/ …
      prefabs/ …
  studio/                         # declarative editor panels (kit-rendered)
    dungeon_generator.panel.jsonc
```

```zig
// plugin.labelle
.{
    .name = "fantasy",
    .manifest_version = 1,
    .resources = .{
        .{ .name = "ui_icons", .json = "assets/ui_icons.json", .texture = "assets/ui_icons.png" },
    },
    .packs = .{ "dungeon", "props" },   // bundled packs (subdirs of packs/)
    // Sold-plugin metadata (informational; surfaced by tooling):
    .license = "commercial — see LICENSE",
    .author = "…",
}
```

```zig
// packs/dungeon/pack.labelle — identical shape for game-local packs
.{
    .name = "dungeon",
    .resources = .{
        .{ .name = "tiles", .json = "assets/tiles.json", .texture = "assets/tiles.png" },
        .{ .name = "props", .json = "assets/props.json", .texture = "assets/props.png", .lazy = true },
    },
    // Overlay content that deliberately draws from GAME atlases declares it,
    // making today's hidden contract explicit and checkable:
    .depends_on_resources = .{ "characters" },
}
```

`.resources` reuses the exact `ResourceDef` shape from `project.labelle`. **Prebuilt atlases are the unit**: a plugin ships packed sheets, not raw sprite sources — deterministic builds, no packer dependency for consumers, and sellers never distribute raw layered art.

### Attaching: one line, as today

```zig
.plugins = .{
    .{ .name = "fantasy", .repo = "github.com/vendor/fantasy-dungeon", .version = "1.2.0" },
},
```

The assembler fetches the plugin, discovers its `.packs`, and registers everything — code, packs, assets — as if the packs were declared individually. The game's own `.resources` is untouched.

### Assembler: merge + namespace + rewrite + validate

1. **Nested-pack discovery.** For each plugin declaring `.packs`, register `<plugin>/packs/<name>/` through the **existing pack machinery** (copy, scan, `pack__` namespacing) exactly as a game-local pack. Pack names must be unique across the game + all attached plugins — a collision is a **generate-time error** naming both providers.
2. **Resource merge.** Pack resources join the game's list as `<pack>__<name>` (`dungeon__tiles`); plugin-level resources as `<plugin>__<name>` (`fantasy__ui_icons`). Downstream codegen (`resource_loader`, `asset_wiring`, `scene_manifests`) consumes the merged list **unchanged**; `@embedFile` paths point into the copied dirs in `.labelle/<target>/`.
3. **Namespace frame names.** At copy time the assembler rewrites the owning unit's atlas JSON frame keys to `<owner>/<frame>` (`dungeon/wall_stone.png`) **and** the `sprite_name` references in that unit's own prefabs/scenes/scripts to match — one mechanical pass, same stage that already rewrites `pack__` prefab refs. Global `findSprite` then cannot collide across units, with **zero engine changes** (path-like frame names are already idiomatic — FP uses `cloud_day/cloud_long_day_7.png` today).
4. **Scene wiring.** A scene that instantiates any prefab from a pack gets that pack's non-lazy resources auto-added to its `SceneAssetManifests` entry (the assembler already knows the prefab→pack mapping from ref rewriting). `lazy` resources ride the streaming catalog and load on first use. Root scenes may also list `"dungeon__tiles"` in `meta.assets` explicitly.
5. **Validation (the silent-blank killer).** At `labelle generate`, every `sprite_name` in a unit's prefabs/scenes must resolve to a frame in (its own shipped atlases) ∪ (atlases named in `depends_on_resources`). Every `depends_on_resources` entry must exist in the merged resource list. Violations are **generate-time errors** with the offending file:line — today's silent runtime blank becomes impossible for plugin/pack content.

### Tilesets and map generators

No new machinery beyond the above. Tiles are entities and tilesets are atlases, so the sold "tile-map plugin with a generator" is: bundled packs carrying tileset atlases + tile/prop prefabs + generator scripts (seeded room/corridor layout spawning tile entities), and optionally a demo scene. `.tmx` templates can ship in `assets/` as plain copied files for the labelle-studio-tmx import path when that lands (deliberately not blocked on it).

### Studio panels: plugin-contributed editor UX

A full plugin should be usable from the editor, not just at runtime — the dungeon vendor's buyer expects a **Dungeon Generator** tab in labelle-studio, not a "run this script" README. Verified state of the studio (investigation, 2026-07-10): **no extension mechanism exists** — panels are a hardcoded Dockview map (`src/features/DockLayout.tsx:24-32`), commands a static array, and the only iframe is the game preview. But three facts make plugin panels cheap:

- the tiles palette is **already a dynamically added/removed Dockview panel** (`DockLayout.tsx:72-88`) — plugin panels reuse that exact lifecycle;
- **data-driven UI is the established studio pattern**: atlas manifests drive the TilePalette, the `.rules.jsonc` sidecar drives the GeneratePanel, the CLI status-file contract drives BuildProgress;
- the **kit already has the widget vocabulary** (`PropertyRow`, `NumField`, `Select`, `SegmentedControl`, …); the only missing piece is a schema→form renderer.

**Design: declaration is static, actions are live.**

A plugin ships declarative panels in a `studio/` convention dir:

```jsonc
// studio/dungeon_generator.panel.jsonc
{
    "id": "dungeon_generator",
    "title": "Dungeon Generator",
    "icon": "grid",
    "fields": [
        { "name": "seed",    "type": "number", "default": 42 },
        { "name": "density", "type": "slider", "min": 0.1, "max": 1.0, "default": 0.5 },
        { "name": "theme",   "type": "select", "options": ["stone", "crypt", "lava"] }
    ],
    "actions": [
        { "label": "Generate",        "command": "generate",       "target": "preview" },
        { "label": "Save as scene…",  "command": "generate_scene", "target": "cli" }
    ]
}
```

- **Discovery + rendering.** The studio's project walk (`src-tauri open_project`) already visits attached-plugin dirs; it collects `studio/*.panel.jsonc` from every attached plugin and registers each through the Dockview API. Panels are rendered by a new **schema→form renderer composed from the kit** — Linear-dark, kit-only rule intact, and **no third-party JS ever executes in the editor** (panels are data, not code).
- **Play-time actions** (`"target": "preview"`) route through the existing game bridge: a new `_editor_plugin_command(plugin, command, params_json)` WASM export (editor-contract bump, same channel family as `editor_set_component`); the engine dispatches it to the plugin's script/hook inside the running preview — the generator spawns its tile entities live.
- **Edit-time actions** (`"target": "cli"`) invoke the plugin's generator through the CLI/file layer (e.g. emit a scene `.jsonc` into the project), so panels remain useful when the game isn't running.
- **Validation**: `panel.jsonc` is schema-checked at `labelle generate` alongside the asset validation — a malformed panel is a generate-time error, and a `preview` command must name a handler the plugin's code declares.

### Distribution and selling

The promotion path covers the full unit with zero restructuring: game-local `packs/dungeon/` → move into a plugin repo's `packs/` + declare in `plugin.labelle` → publish with a git tag. Published plugins fetch by tag into the package cache like today; **private repos** work via standard git credentials — a paid plugin is a private repo the buyer gets access to (the industry-standard asset-store model; no DRM, the license field states terms). Prebuilt sheets mean the sold artifact is the packed atlas, not the source art.

## Backward compatibility

Zero migration:

- Plugins and packs without `.resources`/`.packs` behave exactly as today.
- The game's `.resources` and scene `meta.assets` are untouched; generated output for a project with no asset-bearing plugins is **byte-identical**.
- The frame-name rewrite applies only inside an asset-bearing unit's own copied files; game-side sprite names never change.
- `depends_on_resources` is opt-in — existing overlay packs (sky today) keep working un-declared, just un-validated, until they adopt it.

## Use cases (worked)

1. **Sky pack self-containment (the cheapest live proof).** Move FP's `background`/`cloud` atlases into `packs/sky/assets/` + a `.resources` block; delete the two game-side `.resources` entries and the warning comment. Namespaced `sky__background`/`sky__cloud`, refs rewritten, scenes auto-wired. FP renders pixel-identically — verified by bgfx headless screenshot diff.
2. **Sold full plugin.** `fantasy-dungeon`: two bundled packs (tiles+generator, props), plugin-level UI icons, a **Dungeon Generator studio panel** (seed/density/theme + Generate), license metadata, private repo, version-pinned. Installing = one `.plugins` entry; `labelle generate` validates every sprite ref and the panel schema before first run; the panel appears in the studio with no studio update.
3. **Studio-shared art plugin.** A studio's common UI/character art + widget prefabs as one internal plugin consumed by several games; an art update is a version bump, not a copy-paste sweep.

## Phasing

- **Phase 1 — pack-level resources end-to-end.** `pack.labelle` `.resources`; merge + namespacing; frame-key + `sprite_name` rewrite; generate-time validation; scene auto-wiring. Prove on FP: the sky pack goes self-contained (use case 1). Repos: labelle-assembler (core), labelle-cli (manifest schema surface). Zero engine/gfx changes.
- **Phase 2 — the full plugin.** `plugin.labelle` `.resources` + `.packs` nested-pack discovery + cross-unit pack-name collision detection; `depends_on_resources` validation; license/author metadata surfaced by tooling (`labelle` CLI listing attached plugins + licenses). Prove with a demo plugin repo bundling two packs (use case 2's skeleton).
- **Phase 3 — studio panels.** The `studio/*.panel.jsonc` convention: discovery in the studio's project walk; the kit-composed schema→form renderer; Dockview registration (the tiles-palette lifecycle); `_editor_plugin_command` editor-contract bump for play-time actions + CLI routing for edit-time actions; panel-schema validation in `labelle generate`. Prove with the demo plugin's generator panel driving the running preview. Repos: labelle-studio (renderer + discovery), labelle-engine (bridge export), labelle-assembler (validation).
- **Phase 4 — the marketplace story.** `.tmx` template import (with labelle-studio-tmx); a plugin registry/catalog page (labelle.games); browse attached plugins' sprites in the editor's sprite picker.

## Alternatives considered

1. **Assets only at the pack level, plugins stay code-only.** Rejected (rev 1 proposed this) — the attachable, sellable, version-pinned unit is the *plugin*; making assets pack-only forces vendors to publish N packs instead of one product and leaves plugin code that draws (debug overlays, UI kits) with no art channel.
2. **Re-pack raw sprites into the game's atlases at build time.** Rejected as the default — requires shipping raw art (kills the sold-plugin story), adds a packer dependency to every consumer build, and makes builds non-deterministic across packer versions. Possible future opt-in for *local* packs where batching matters more than opacity.
3. **Runtime asset discovery (scan a directory at startup).** Rejected — the pipeline is comptime `@embedFile` + generated manifests; a runtime path would fork every downstream seam (ASTC, streaming, scene preload) and reintroduce silent late failures.
4. **Keep frame names global, namespace only atlas names.** Rejected — `findSprite` searches across atlases, so two units shipping `grass.png` still collide; rewriting frame keys at copy time closes the hole with zero engine changes.
5. **Sandboxed webview panels (plugin ships its own web UI).** Rejected for v1 — unlimited flexibility, but it breaks the studio's kit-only rule (visual consistency), opens a security surface (vendor JS executing in the editor), and adds a Tauri webview dependency. Declarative kit-rendered panels cover the generator/params use cases; the webview escape hatch can be revisited if a real panel outgrows the schema.
6. **Plugin panels via the digest only (game-runtime-declared, no manifest).** Rejected as the primary path — panels would exist only while the game runs; a generator panel should also work at edit time (emit a scene file). The static `panel.jsonc` declaration + dual `preview`/`cli` action targets covers both; the digest remains the *state* channel, not the *declaration* channel.

## Open questions

- **Nested-pack namespacing.** Bundled packs keep their own flat namespace (`dungeon__*`, colliding-name error) vs plugin-qualified (`fantasy__dungeon__*`, uglier but collision-free). Leaning flat + generate-time error — names stay short and the error is actionable (rename the pack).
- **Auto-wiring granularity.** Auto-adding a pack's resources to every scene that uses any of its prefabs is coarse (one prop pulls the pack's whole non-lazy set). Per-prefab asset attribution is computable by the validator — worth it in Phase 1 or defer?
- **Loose sprites.** Should a unit be able to ship un-atlased single PNGs (`assets/loose/*.png`) that the assembler packs at generate time via the built-in MaxRects packer? Convenient for tiny plugins; blurs the prebuilt-first rule.
- **Sound/font resources.** `ResourceDef` already carries `sound`/`font` — plugins/packs get them "for free" through the same merge. Bless in Phase 1 or restrict to atlases first?
- **Frame-name rewrite format.** `<owner>/<frame>` (path-like, matches existing idiom; studio sprite picker groups by directory) vs `<owner>__<frame>` (matches key convention). Leaning path-like.
- **Panel widget vocabulary v1.** `number`/`slider`/`select`/`text`/`toggle`/`button` covers the generator case; do lists/tables (e.g. "generated rooms" preview) make v1 or wait for a real demand?
- **Panel state persistence.** Do panel field values persist per-project (in `.labelle/` state or project extras) or reset per session? Leaning per-project persistence — a seed you liked shouldn't vanish on restart.
- **Command handler declaration.** How a plugin's code declares which `preview` commands it handles (comptime hook registration vs a manifest list the validator checks) — decide in Phase 3 design.
