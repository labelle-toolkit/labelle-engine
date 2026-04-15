# RFC: Asset Streaming

**Status:** Draft
**Author:** Alexandre
**Date:** 2026-04-15

## Problem

Cold-start time on a Galaxy Tab A7 was 25 s before the recent atlas downscale + lazy-register work brought it to 11 s. The remaining 11 s is dominated by synchronous PNG decode on the main thread:

- `loadAtlasFromMemory` decodes inline. Calling it during a frame freezes the screen. This is why the loading-screen attempt earlier in the session failed — the bar never repainted because the very call meant to let it animate was the call blocking the thread.
- The lazy variant (`registerPendingAtlas` + `loadAtlasIfNeeded`, engine #434) defers decode but is *still* synchronous when the deferred call eventually fires. We bought "decode later" but not "decode without freezing."
- Scenes don't declare which atlases they need. Game scripts call `loadAtlasIfNeeded(name)` manually — easy to forget, easy to load the wrong set, no engine-level guarantee that a scene's required assets are ready before it ticks.
- There is no unload path. Atlases live for the lifetime of the process. For FP today that's fine; for any larger project it's a memory ceiling we'll hit and have to retrofit around.
- Atlases are the only asset type with *any* streaming machinery. Audio and fonts will arrive soon and would otherwise repeat all four mistakes from scratch.

The big-engine playbook (Unity Addressables, Unreal soft references + StreamableManager, Godot threaded `ResourceLoader`) converges on five primitives: a metadata catalog, an async API, refcounted unload, soft-vs-hard refs declared at build time, and a spatial/scene trigger that batches loads. labelle-engine has #1 (after #434) and #4 (after assembler #44). This RFC adds #2, #3, and #5, and generalises the machinery beyond atlases so audio and fonts inherit it for free.

## Goals

1. **Async decode** — PNG (and later OGG, TTF) decode runs on a worker thread; the main loop keeps ticking and a loading screen can actually animate.
2. **Per-scene asset manifests** — scenes declare their assets in the `.jsonc` file; the engine acquires/releases them on transition.
3. **Reference-counted unload** — assets that no live scene needs get freed automatically.
4. **Generic across asset types** — one `AssetCatalog` + per-type `AssetLoader` plug-in pattern. Atlas, audio, font, raw bytes all flow through the same primitives.
5. **Backwards-compatible** — existing `loadAtlasFromMemory` remains as a sync convenience wrapping the new path.

## Non-goals

- **Network/CDN fetching.** labelle-toolkit ships embedded binaries (`@embedFile`) by design. Remote fetch is its own RFC.
- **Hot reload.** Reloading mutated assets at runtime is a separate concern and conflicts with `@embedFile` semantics anyway.
- **Asset dependency graphs.** Atlases today are leaf assets (one PNG + one JSON). A future "prefab references atlases" graph can layer on later; v1 treats every asset as independent.
- **Multi-threaded decoders.** One worker thread is enough to absorb a typical scene's load list during a loading screen. A pool can come later if profiling demands it.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Game / Scripts                                                 │
│    g.assets.acquire("background")  →  AssetHandle               │
│    g.assets.isReady("background")                               │
│    g.assets.release("background")                               │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  AssetCatalog  (labelle-engine/src/assets/catalog.zig)          │
│    StringHashMap(AssetEntry)                                    │
│      state: { registered, queued, decoding, ready, error }     │
│      refcount: u32                                              │
│      loader: *const AssetLoaderVTable                           │
│      raw_bytes / file_type   (borrowed, lives for program)      │
│      decoded:  union { texture: TextureId, audio: …, font: … }  │
└─────────────────────────────────────────────────────────────────┘
        │                                       ▲
        │ enqueue(entry)              upload() (main thread)
        ▼                                       │
┌──────────────────────────┐     ┌──────────────────────────────┐
│  AssetWorker (1 thread)  │     │  Main thread upload pump     │
│    bounded MPSC queue    │ ──▶ │   drains decoded-but-not-    │
│    decode → raw pixels   │     │   uploaded queue, calls      │
│    push to upload queue  │     │   backend.uploadTexture()    │
└──────────────────────────┘     └──────────────────────────────┘
```

Decode happens off-thread. Upload (the GPU call) happens on the main thread because both sokol_gfx and raylib's GL backend are single-threaded by spec — there is no portable way to upload from a worker. The split is the same pattern Unity, Unreal and Godot all use under the hood.

## Per-layer changes

### 1. labelle-gfx — backend contract

Add to backend interface:

```zig
/// Decode an embedded image to raw RGBA8 pixels. Pure CPU, safe to
/// call from a worker thread. Returns owned pixel buffer + dims.
pub fn decodeImage(
    file_type: [:0]const u8,
    data: []const u8,
    allocator: Allocator,
) !DecodedImage;

pub const DecodedImage = struct {
    pixels: []u8,    // RGBA8, allocator-owned
    width:  u32,
    height: u32,
};

/// Upload pre-decoded pixels to a GPU texture. MUST be called from
/// the main / GL thread.
pub fn uploadTexture(decoded: DecodedImage) !Texture;
```

The existing `loadTextureFromMemory` becomes a convenience: `decodeImage` + `uploadTexture` back-to-back on the calling thread. Same return type, same error set, no caller-side break.

`decodeImage` for stb (sokol/raylib both ship it) is just `stbi_load_from_memory` into an allocator-owned buffer instead of the static one. For the mock backend it returns a stub `1×1` decoded buffer.

### 2. labelle-engine — `AssetCatalog` + worker

New module: `src/assets/`

```
src/assets/
  catalog.zig       ← public AssetCatalog API
  worker.zig        ← std.Thread + bounded queue
  loader.zig        ← AssetLoaderVTable (decode/upload/free)
  loaders/
    image.zig       ← uses gfx decodeImage/uploadTexture
    audio.zig       ← stub for now (panics on load)
    font.zig        ← stub for now (panics on load)
```

Game gets:

```zig
g.assets.register(name, loader_kind, file_type, bytes);  // metadata only
g.assets.acquire(name)   → *AssetEntry  // bumps refcount, enqueues if needed
g.assets.release(name)                  // drops refcount, unloads on zero
g.assets.isReady(name)   → bool
g.assets.pump()                         // called once per frame from game loop;
                                        // drains the upload queue
```

The existing atlas-specific `RuntimeAtlas.pending` mechanism (engine #434) collapses into `AssetCatalog` — `loadAtlasIfNeeded` becomes `acquire("atlas:" ++ name)` plus a busy-wait on `isReady` for back-compat. The lazy registration done by the assembler now goes through `g.assets.register("atlas:foo", .image, ".png", @embedFile(...))` instead of `g.registerAtlasFromMemory(...)`.

`pump()` is a one-line addition to the existing per-frame work in `Game.tick`. It drains decoded-but-not-uploaded entries by calling the loader's main-thread upload step; cap at N per frame to avoid hitch spikes when many assets land at once (start with N=4, tune later).

### 3. labelle-engine — scene transition hooks

`SceneLoader` already has `enterScene` / `exitScene` hooks. Add two phases:

```
exitScene(old):
  for asset in old.manifest.assets:
    catalog.release(asset)

enterScene(new):
  for asset in new.manifest.assets:
    catalog.acquire(asset)
  // game tick is gated until catalog.allReady(new.manifest.assets)
  // — the loading screen scene runs in the meantime
```

The "loading screen scene" is just a regular scene with its own (small) manifest that's eager-loaded at startup. The engine swaps to it on `setScene`, runs the worker until the target's manifest is ready, then completes the transition.

### 4. Scene file — `assets:` block

Add to `scene.jsonc`:

```jsonc
{
  "assets": ["background", "ship", "rooms"],
  "entities": [ … ]
}
```

Optional. Omitted = no preload, scripts manage manually (legacy path).

### 5. labelle-assembler — manifest emission

Two changes:

1. When parsing each scene `.jsonc`, collect the `assets:` array. Emit a comptime map: `scene_name → []const []const u8`. The engine reads this map in `enterScene`.
2. `lazy: true` on `project.labelle` resources becomes the default. The fallback for resources that no scene declares stays eager (back-compat for projects that don't migrate).

### 6. Audio + font loaders

Stub `audio.zig` and `font.zig` panic on `decode()` for v1, but the registration path works — projects can declare audio/font assets in `project.labelle` and the assembler/catalog plumbing is exercised. Real loaders land in follow-up RFCs (one per format) without re-touching the streaming machinery.

## Example: FP loading screen, post-RFC

```jsonc
// scenes/loading.jsonc
{
  "assets": ["loading_bar"],   // tiny, eager
  "entities": [ … bar setup … ]
}

// scenes/main.jsonc
{
  "assets": ["background", "rooms", "ship", "characters", "objects", "cloud"],
  "entities": [ … game setup … ]
}
```

```zig
// scripts/loading_controller.zig
pub fn tick(game: anytype, state: anytype, _: anytype, _: f32) void {
    const target = "main";
    const ready = game.assets.allReady(game.scenes.get(target).assets);
    state.bar_scale = game.assets.progress(game.scenes.get(target).assets);
    if (ready) game.setScene(target);
}
```

The bar animates because decode is on the worker thread. Scene transition is automatic. No manual `loadAtlasIfNeeded` calls anywhere.

## Migration plan

1. **Phase 1 — primitives (this RFC):**
   - Add `gfx.decodeImage` / `gfx.uploadTexture` (sokol + raylib + mock).
   - Add `AssetCatalog`, `AssetWorker`, `image` loader.
   - `loadAtlasFromMemory` and `loadAtlasIfNeeded` become sync wrappers over `acquire` + busy-wait.
   - Status: green CI, no caller break, no behavior change for existing projects.

2. **Phase 2 — scene manifests:**
   - Scene loader reads `assets:` block, calls `acquire`/`release` on transition.
   - Assembler emits the per-scene asset map.
   - FP migrates `main.jsonc` to use the manifest. Cold start should drop further as the loading screen actually animates.

3. **Phase 3 — refcount unload:**
   - Catalog frees assets on `refcount == 0`.
   - Validate against FP (it has only one main scene, so unload mostly happens at shutdown).

4. **Phase 4 — audio + font loaders:**
   - Real `decodeAudio` / `decodeFont` backend hooks; one follow-up RFC per format.

Each phase ships as its own PR set across `labelle-gfx`, `labelle-engine`, `labelle-assembler`. Phases 1 and 2 deliver the cold-start win; 3 and 4 are quality-of-life follow-ups.

## Open questions

1. **Worker pool vs single thread.** Single thread is simpler and enough for FP. If a project ever needs to load 50+ atlases in parallel during a loading screen, we'd want a small fixed-size pool. Defer until profiling shows contention.
2. **Upload throttle (`N` per frame in `pump()`).** Starting value is a guess; needs measurement on the Galaxy Tab to confirm 4/frame doesn't hitch.
3. **Error propagation.** A decode failure should mark the asset `error` and surface via `isReady` returning false plus a `lastError(name)` accessor — but should it be fatal at `setScene` time, or let the scene run with a missing texture? Probably configurable, default fatal.
4. **Scene-as-asset.** Should scene `.jsonc` themselves go through the catalog? Symmetrically clean, but they're tiny and eager-load from `@embedFile` is fine. Punt unless a real need shows up.
5. **`acquire` from non-main threads.** v1 makes the catalog single-threaded (acquire/release on main). Worker only touches its own queue. If scripts ever run on worker threads (they don't today), revisit.
