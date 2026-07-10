# RFC: Asset Packs — sprites, atlases, and tilesets in packs

**Issue:** labelle-toolkit/labelle-engine#725  
**Status:** Draft  
**Author:** Alexandre  
**Date:** 2026-07-10

## Problem

Packs are labelle's game-content unit: a pack ships components, scripts, prefabs, and events, dir-scanned and namespaced (`pack__*`), promotable from a local `packs/` directory to a published version-pinned repo with a `mv` and a pin. But packs **cannot ship the art their prefabs draw**.

The consequence is a hidden contract. Flying-Platform's `sky` pack renders backdrops and clouds — and its prefabs carry a warning comment that the assembler *"expects the `background` + `cloud` atlases in the scene meta"*: the **game** must hand-declare, in its own `project.labelle` `.resources`, atlases whose frame names happen to match what the pack's prefabs reference. Nothing checks this. A missing atlas or a misspelled frame is a **silent runtime blank** (sprite lookup returns nothing; no error).

This blocks the natural end-game of the packs story:

- a pack cannot be **self-contained** (sky should bring its own sky art);
- a studio cannot share **versioned art** across its games except by copy-paste;
- nobody can build the obvious third-party product: a **sold tileset + map-generator pack** — prebuilt sheets, generator scripts, demo prefabs, one `project.labelle` entry to install.

### Scope: packs, not plugins

Plugins and packs are different units and stay different. **Plugins** extend the *engine* — code capabilities (pathfinding, fsm, imgui). **Packs** extend the *game* — content. Assets are content, so this RFC gives assets to **packs**. Plugins shipping assets is a **non-goal** (the two share assembler copy machinery, and nothing here prevents revisiting later, but no plugin surface changes in this design).

## Verified current architecture (investigation, 2026-07-10)

The pipeline, end to end, with the seams this RFC builds on:

- **Authoring → atlas.** `labelle pack <dir>` (MaxRects, `labelle-cli/src/cli/pack.zig:22-86`, `src/texpack/`) or free-tex-packer (`.ftpp`, FP's choice) → a `<name>.png` sheet + `<name>.json` in **TexturePacker JSON-hash** format: `frames{ name → frame{x,y,w,h}, rotated, trimmed, spriteSourceSize, sourceSize, pivot }` + `meta{image,size}`. Both packers emit the same schema — the consumer is packer-agnostic.
- **Game-side declaration.** `project.labelle` `.resources = .{ .{ .name, .json, .texture, .lazy }, … }` (`ResourceDef`, also `sound`/`font` variants — `labelle-cli/src/cli/project_config.zig:130-150`). Scenes preload by name: `{"meta": {"assets": ["background", "cloud", …]}}` → codegen'd `SceneAssetManifests` (`labelle-assembler/src/codegen/blocks/scene_manifests.zig:37-99`).
- **Codegen.** `resource_loader.zig:52-112` emits, per resource, eager `g.loadAtlasFromMemory(name, @embedFile(json), @embedFile(png), ".png")` or lazy `registerAtlasFromMemory(...)`. `asset_wiring.zig:49-160` carries the **compressed-texture seam** (ASTC: `isCompressed`/`uploadCompressed` `@hasDecl` gates, engine#450). The lazy path feeds the **streaming catalog** (`labelle-engine/src/assets/catalog.zig`: worker decode, bounded rings, upload budget — RFC-ASSET-STREAMING).
- **Runtime lookup is global and un-namespaced.** `game.findSprite(name)` searches **every loaded atlas** by frame name. Prefab/event/component keys are `pack__`-prefixed by the assembler at copy time; **sprite frame names are not**. Two atlases sharing a frame name = undefined winner; a missing atlas = silent blank.
- **Packs already have an `assets/` dir — copied but dead.** `assets/` is in the assembler's reserved convention dirs (`plugin_manifest.zig:19-30`) and is recursively copied from packs (`root.zig:530-632`), but nothing registers the copied files: no `.resources` merge, no embed, no manifest entry. Pack-shipped art is unreachable today.
- **Tilesets are just atlases.** Tiles are ordinary `Position`+`Sprite` entities; a tileset PNG is packed like any sprite set (labelle-studio-tmx RFC-tilemap). So a "map generator" is ordinary pack *scripts* spawning tile entities — code packs can already ship it; only the art half is missing.
- **Distribution already works.** `@packs/<name>` local dir → published repo + `.version` git-tag fetch into the package cache, `labelle.lock` pinning. Private repos ride git credentials.

**The key architectural fact:** the extension point is the assembler's **resource merge**. If packs contribute `ResourceDef` entries into the same list the game's `.resources` feeds, everything downstream — embed, ASTC, lazy streaming, scene manifests — works unchanged. The runtime never needs to know packs exist.

## Proposal

Packs declare the atlases they ship; the assembler merges them into the game's resource catalog **namespaced**, rewrites the pack's own sprite references to match, and validates every reference at generate time.

### Pack layout + manifest

```text
packs/dungeon/
  pack.labelle
  assets/
    tiles.png        # prebuilt atlas sheet (packed, not raw art)
    tiles.json       # TexturePacker JSON-hash (labelle pack / free-tex-packer)
    props.png
    props.json
  prefabs/ …          # reference "wall_stone.png" etc. from those atlases
  scripts/ …          # e.g. the dungeon generator
```

```zig
// pack.labelle
.{
    .name = "dungeon",
    .manifest_version = 1,
    .resources = .{
        .{ .name = "tiles", .json = "assets/tiles.json", .texture = "assets/tiles.png" },
        .{ .name = "props", .json = "assets/props.json", .texture = "assets/props.png", .lazy = true },
    },
    // Overlay packs that deliberately draw from GAME atlases declare it,
    // making today's hidden contract explicit and checkable:
    .depends_on_resources = .{ "characters" },
    // Sold-pack metadata (informational; surfaced by tooling):
    .license = "CC-BY-4.0",
    .author = "…",
}
```

`.resources` reuses the exact `ResourceDef` shape from `project.labelle` (json/texture/lazy — `sound`/`font` variants come along for free, though sprites are this RFC's focus). **Prebuilt atlases are the unit**: a pack ships packed sheets, not raw sprite sources — deterministic builds, no packer dependency for consumers, and sellers never distribute raw layered art.

### Assembler: merge + namespace + rewrite

1. **Merge.** Pack resources join the game's list as `<pack>__<name>` (`dungeon__tiles`) — same prefix convention as prefabs/events/components. Downstream codegen (`resource_loader`, `asset_wiring`, `scene_manifests`) consumes the merged list **unchanged**; `@embedFile` paths point into the copied pack dir in `.labelle/<target>/`.
2. **Namespace frame names.** At copy time the assembler rewrites the pack's atlas JSON frame keys to `<pack>/<frame>` (`dungeon/wall_stone.png`) **and** the `sprite_name` references in the pack's own prefabs/scenes to match — one mechanical pass, same stage that already rewrites `pack__` prefab refs. Global `findSprite` then cannot collide across packs, with **zero engine changes** (path-like frame names are already idiomatic — FP uses `cloud_day/cloud_long_day_7.png` today).
3. **Scene wiring.** A scene that instantiates any prefab from a pack gets that pack's non-lazy resources auto-added to its `SceneAssetManifests` entry (the assembler already knows the prefab→pack mapping from ref rewriting). `lazy` resources ride the streaming catalog and load on first use. Root scenes may also list `"dungeon__tiles"` in `meta.assets` explicitly.
4. **Validation (the silent-blank killer).** At `labelle generate`, every `sprite_name` in a pack's prefabs/scenes must resolve to a frame in (its own shipped atlases) ∪ (atlases named in `depends_on_resources`). Every `depends_on_resources` entry must exist in the game's `.resources`. Violations are **generate-time errors** with the offending file:line — today's silent runtime blank becomes impossible for packs.

### Game-side surface

Nothing new to author for the common case. Installing an asset pack is the existing pack flow:

```zig
.plugins = .{
    .{ .name = "dungeon", .repo = "github.com/vendor/dungeon-pack", .version = "1.2.0" },
},
```

The game's own `.resources` is untouched. Game scenes/prefabs may reference pack sprites explicitly by their namespaced names (`"dungeon/wall_stone.png"`) once the pack is installed.

### Tilesets and map generators

No new machinery. Tiles are entities and tilesets are atlases, so a sold "tile map pack with a generator" is: `assets/` (tileset atlases) + `scripts/` (the generator spawning tile entities, e.g. seeded room/corridor layout) + `prefabs/` (tile/prop prefabs) + optionally a demo scene. This RFC's asset half completes the unit; the code half works today (pathfinding-style script shipping). `.tmx` templates can ship in `assets/` as plain copied files for the labelle-studio-tmx import path when that lands (deliberately not blocked on it).

### Distribution and selling

The 3-tier promotion path covers assets with zero restructuring: local `packs/dungeon/` → `mv` to its own repo → `.version` pin. Published packs are fetched by git tag into the package cache like plugins; **private repos** work via standard git credentials — a paid pack is a private repo the buyer gets access to (the industry-standard asset-store model; no DRM, license field in `pack.labelle` states terms). Prebuilt sheets mean the sold artifact is the packed atlas, not the source art.

## Backward compatibility

Zero migration:

- Packs without `.resources` behave exactly as today (their `assets/` still just copies).
- The game's `.resources` and scene `meta.assets` are untouched; generated output for a project with no asset packs is **byte-identical**.
- The frame-name rewrite applies only inside a pack's own copied files; game-side sprite names never change.
- `depends_on_resources` is opt-in — existing overlay packs (sky today) keep working un-declared, just un-validated, until they adopt it.

## Use cases (worked)

1. **Sky pack self-containment (the live proof).** Move FP's `background`/`cloud` atlases into `packs/sky/assets/` + a `.resources` block; delete the two game-side `.resources` entries and the warning comment. The assembler namespaces them `sky__background`/`sky__cloud`, rewrites the pack's frame refs, auto-wires scenes that use `sky__sky_system`. FP renders pixel-identically — verified by bgfx headless screenshot diff.
2. **Sold dungeon pack.** Prebuilt tile/prop atlases + generator scripts + prefabs, private repo, version-pinned. Installing = one `.plugins` entry; `labelle generate` validates every sprite ref before first run.
3. **Studio-shared UI pack.** Common button/icon atlases + widget prefabs, versioned once, consumed by several games; an art update is a version bump, not a copy-paste sweep.

## Phasing

- **Phase 1 — pack resources end-to-end.** `pack.labelle` `.resources` parsing; merge + `<pack>__` namespacing; frame-key + `sprite_name` rewrite at copy time; generate-time validation; scene auto-wiring for non-lazy resources. Prove on FP: the sky pack goes self-contained (use case 1). Repos: labelle-assembler (core), labelle-cli (`pack.labelle` schema surface). Zero engine/gfx changes.
- **Phase 2 — the contract surface.** `depends_on_resources` validation; `license`/`author` metadata surfaced by tooling (`labelle` CLI listing installed packs + licenses); lazy/streaming polish for large packs (upload-budget interaction with many pack atlases).
- **Phase 3 — the marketplace story.** `.tmx` template import (with labelle-studio-tmx); a pack registry/catalog page (labelle.games); studio integration — browse installed packs' sprites in the editor's sprite picker.

## Alternatives considered

1. **Plugins carry assets.** Rejected — plugins are the engine-capability unit, packs are the content unit; blurring them costs the clean promotion path and the namespacing conventions packs already have.
2. **Re-pack raw sprites into the game's atlases at build time.** Rejected as the default — requires shipping raw art (kills the sold-pack story), adds a packer dependency to every consumer build, and makes builds non-deterministic across packer versions. Noted as a possible future opt-in for *local* packs where batching matters more than opacity.
3. **Runtime asset discovery (scan a directory at startup).** Rejected — the whole pipeline is comptime `@embedFile` + generated manifests; a runtime path would fork every downstream seam (ASTC, streaming, scene preload) and reintroduce silent late failures.
4. **Keep frame names global, namespace only atlas names.** Rejected — `findSprite` searches across atlases, so two packs shipping `grass.png` still collide; rewriting frame keys at copy time closes the hole with zero engine changes.

## Open questions

- **Auto-wiring granularity.** Auto-adding a pack's resources to every scene that uses any of its prefabs is coarse (a scene using one prop pulls the pack's whole non-lazy set). Per-prefab asset attribution is possible (the validator computes exactly which frames each prefab uses) — worth it in Phase 1 or defer?
- **Loose sprites.** Should a pack be able to ship un-atlased single PNGs (`assets/loose/*.png`) that the assembler packs at generate time via the built-in MaxRects packer? Convenient for tiny packs; blurs the prebuilt-first rule.
- **Sound/font resources.** `ResourceDef` already carries `sound`/`font` — packs get them "for free" through the same merge. Bless that in Phase 1 or explicitly restrict to atlases first?
- **Frame-name rewrite format.** `<pack>/<frame>` (path-like, matches existing idiom) vs `<pack>__<frame>` (matches pack key convention). Leaning path-like — sprite names are already paths and the studio sprite picker groups by directory.
