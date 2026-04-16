# RFC: Asset Streaming

**Status:** Draft (revision 3 — addresses second-round review on rev 2)
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
5. **Backwards-compatible at the API surface** — existing `loadAtlasFromMemory` keeps working as a sync wrapper. (Caveat: the wrapper is still a main-thread block — see Migration §Phase 1. The cold-start UX win lands in Phase 2 when scene transitions go through the catalog without the sync wrapper.)

## Non-goals

- **Network/CDN fetching.** labelle-toolkit ships embedded binaries (`@embedFile`) by design. Remote fetch is its own RFC.
- **Hot reload.** Reloading mutated assets at runtime is a separate concern and conflicts with `@embedFile` semantics anyway.
- **Asset dependency graphs.** Atlases today are leaf assets (one PNG + one JSON). A future "prefab references atlases" graph can layer on later; v1 treats every asset as independent.
- **Multi-threaded decoders.** One worker thread is enough to absorb a typical scene's load list during a loading screen. A pool can come later if profiling demands it.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Game / Scripts (main thread)                                   │
│    g.assets.acquire("background")  →  AssetHandle               │
│    g.assets.isReady("background")                               │
│    g.assets.release("background")                               │
│    g.assets.allReady(slice) / progress(slice) / lastError(name) │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  AssetCatalog  (labelle-engine/src/assets/catalog.zig)          │
│    StringHashMap(AssetEntry)                                    │
│      state: { registered, queued, decoding, ready, failed }     │
│      refcount: u32                                              │
│      loader: *const AssetLoaderVTable                           │
│      raw_bytes / file_type   (borrowed @embedFile, see below)   │
│      decoded:  union { texture: TextureId, audio: …, font: … }  │
│      last_error: ?anyerror                                      │
└─────────────────────────────────────────────────────────────────┘
        │ enqueue(WorkRequest)            ▲ drain WorkResult
        │  (SPSC: main → worker)          │  (SPSC: worker → main)
        ▼                                 │
┌──────────────────────────┐     ┌──────────────────────────────┐
│  AssetWorker (1 thread)  │     │  Main thread upload pump     │
│    pulls WorkRequest     │ ──▶ │    drains WorkResult queue,  │
│    calls loader.decode() │     │    refcount-checks, then     │
│    pushes WorkResult     │     │    calls loader.upload(...)  │
│    NEVER mutates         │     │    via the vtable — generic  │
│    AssetEntry directly   │     │    across asset types        │
└──────────────────────────┘     └──────────────────────────────┘
```

Decode happens off-thread. Upload (the GPU call, or audio device init, or font glyph rasterise) happens on the main thread because both sokol_gfx and raylib's GL backend are single-threaded by spec — there is no portable way to upload from a worker. The split is the same pattern Unity, Unreal and Godot all use under the hood.

**Threading invariant:** `AssetEntry` is owned exclusively by the main thread. The worker only reads `WorkRequest` (a snapshot — entry id, loader pointer, borrowed bytes, file_type) and writes `WorkResult` (entry id + decoded payload OR error) back. State transitions (`queued → decoding → ready/failed`) and refcount changes happen only inside `pump()` and the public catalog methods, so no mutex is needed on the catalog itself. Both queues are bounded SPSC ring buffers.

**Embedded byte lifetime:** All `raw_bytes` and `file_type` slices originate from `@embedFile` in the assembler-generated init code, so they live for the entire program. The catalog stores them as borrowed slices without copying. This is the same lifetime guarantee that engine #434's `PendingImage` already relies on.

## Per-layer changes

### 1. labelle-gfx — backend contract

Add to backend interface:

```zig
/// Decode an embedded image to raw RGBA8 pixels. Pure CPU, safe to
/// call from a worker thread. The returned `pixels` slice is owned
/// by `allocator` — the caller (loader.upload, see below) is
/// responsible for freeing it after the GPU upload OR after deciding
/// to discard the result.
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
/// the main / GL thread. Does NOT free `decoded.pixels` — the caller
/// frees, since the catalog needs to free on the discard path too.
pub fn uploadTexture(decoded: DecodedImage) !Texture;
```

The existing `loadTextureFromMemory` becomes a convenience: `decodeImage` + `uploadTexture` + free, back-to-back on the calling thread. Same return type, same error set, no caller-side break.

`decodeImage` for stb (sokol/raylib both ship it) is just `stbi_load_from_memory` into an allocator-owned buffer instead of the static one. For the mock backend it returns a stub `1×1` decoded buffer.

### 2. labelle-engine — `AssetCatalog` + worker

New module: `src/assets/`

```
src/assets/
  catalog.zig       ← public AssetCatalog API + AssetEntry
  worker.zig        ← std.Thread + 2× bounded SPSC ring buffers
  loader.zig        ← AssetLoaderVTable { decode, upload, free, drop }
  loaders/
    image.zig       ← uses gfx.decodeImage / gfx.uploadTexture
    audio.zig       ← stub (decode returns error.LoaderNotImplemented)
    font.zig        ← stub (decode returns error.LoaderNotImplemented)
```

`AssetLoaderVTable`:

```zig
pub const AssetLoaderVTable = struct {
    /// Worker-thread CPU decode. Allocator-owned output stored in
    /// `WorkResult.decoded`. May return error → result.err set.
    decode: *const fn (file_type: [:0]const u8, data: []const u8, allocator: Allocator) anyerror!DecodedPayload,

    /// Main-thread finalise: GPU upload, audio device handle, font
    /// glyph rasterise — whatever turns the worker output into the
    /// "ready" representation. ALSO frees the CPU-side payload
    /// (success path).
    upload: *const fn (entry: *AssetEntry, decoded: DecodedPayload) anyerror!void,

    /// Discard path: refcount hit zero between decode and upload.
    /// Frees the CPU-side payload without touching the GPU.
    drop: *const fn (allocator: Allocator, decoded: DecodedPayload) void,

    /// Unload path: refcount hit zero on a `ready` asset. Releases
    /// the GPU/audio/font resource the upload created.
    free: *const fn (entry: *AssetEntry) void,
};
```

Game gets:

```zig
g.assets.register(name, loader_kind, file_type, bytes);   // metadata only
g.assets.acquire(name)    → *AssetEntry  // bumps refcount, enqueues if needed
g.assets.release(name)                   // drops refcount, unloads on zero
g.assets.isReady(name)    → bool         // entry.state == .ready
g.assets.allReady(names)  → bool         // every name in slice is ready
g.assets.progress(names)  → f32          // 0..1, ready_count / names.len
g.assets.lastError(name)  → ?anyerror    // set on .failed
g.assets.anyFailed(names) → bool         // any name in slice is .failed
g.assets.resetFailed(name)               // .failed → .registered, clears last_error;
                                         // lets a future acquire retry the load
g.assets.pump()                          // called once per frame from game loop
```

Names are unique across loader kinds — the loader is selected by the `loader_kind` argument at registration time, then stored on the entry, so callers don't need a `"atlas:"` prefix. The assembler-generated registration code uses each resource's plain `name` from `project.labelle`.

`pump()` body:

```zig
pub fn pump(self: *AssetCatalog) void {
    var drained: u8 = 0;
    while (drained < UPLOAD_BUDGET_PER_FRAME) : (drained += 1) {
        const result = self.worker.tryRecvResult() orelse return;
        const entry = self.entries.getPtr(result.entry_id) orelse continue;

        // ── 1. Decode failure first.
        // Worker reported an error → result.decoded is undefined and
        // MUST NOT be passed to drop/upload. Surface the error and
        // move on. The entry's refcount stays where the caller left
        // it — the caller releases on its own error path.
        if (result.err) |err| {
            entry.last_error = err;
            entry.state = .failed;
            continue;
        }

        // ── 2. Released while decoding → discard.
        // The entry is still alive (release only frees on .ready),
        // but no one wants the result anymore. drop() owns + frees
        // result.decoded. Reset to .registered so a future acquire
        // can re-trigger the decode.
        if (entry.refcount == 0) {
            entry.loader.drop(self.allocator, result.decoded);
            entry.state = .registered;
            continue;
        }

        // ── 3. Upload (success path frees inside upload).
        // Upload failure must also free result.decoded — upload's
        // contract only says "frees on success", so we drop on the
        // catch branch to avoid leaking the (potentially large) RGBA8
        // buffer every time a GPU upload fails.
        entry.loader.upload(entry, result.decoded) catch |err| {
            entry.loader.drop(self.allocator, result.decoded);
            entry.last_error = err;
            entry.state = .failed;
            continue;
        };
        entry.state = .ready;
    }
}
```

`UPLOAD_BUDGET_PER_FRAME` starts at 4 — tunable, see Open Questions.

The existing atlas-specific `RuntimeAtlas.pending` mechanism (engine #434) collapses into `AssetCatalog` — `loadAtlasIfNeeded` becomes a pump-driven sync shim:

```zig
pub fn loadAtlasIfNeeded(self: *Game, name: []const u8) !void {
    try self.assets.acquire(name);
    // Release on every error path so a failed/retry cycle doesn't
    // leak refcount. On success the caller eventually calls
    // unloadAtlas (or scene release) which is the matching release.
    errdefer self.assets.release(name);

    while (!self.assets.isReady(name)) {
        if (self.assets.lastError(name)) |err| {
            // Reset .failed → .registered so the next acquire retries
            // (transient failures shouldn't be permanent — see Open
            // Questions §7).
            self.assets.resetFailed(name);
            return err;
        }
        self.assets.pump();           // CRITICAL: without this, deadlock —
                                      // isReady only flips inside pump
        std.Thread.yield() catch {};  // YieldError!void (Windows quirk), must catch
    }
}
```

This shim still blocks the calling frame (decode is async but the wait is sync), so it freezes the main thread the same way the current `loadAtlasFromMemory` does. Phase 1 deliberately preserves that behavior to keep the caller surface unchanged; Phase 2 introduces the non-blocking path via scene manifests.

### 3. labelle-engine — scene transition wiring

Today's scene loader exposes `setScene` + `setSceneAtomic` and emits hooks `scene_before_load` and `scene_load`. Phase 2 introduces two new built-in hooks fired from `setScene`:

- `scene_assets_acquire(target)` — fired *before* `scene_before_load` for the new scene.
- `scene_assets_release(previous)` — fired *after* `scene_load` for the new scene completes.

The engine's default handler implements:

```
setScene(target):
  # Idempotent re-entry: if the previous setScene call already
  # acquired this same target and parked us in the loading scene
  # waiting on it, don't acquire a SECOND time. The pending_target
  # field is cleared once the swap completes (or is replaced by a
  # different target).
  if pending_target != target:
    # Acquire NEW first so shared assets keep refcount ≥ 1 across
    # the swap and don't get freed-then-reloaded.
    for asset in target.manifest.assets:
      catalog.acquire(asset)
    pending_target = target

  # Still decoding → park in the loading scene. The loading scene's
  # tick re-enters setScene(target) every frame; the idempotency
  # check above keeps the acquire from happening again.
  #
  # CRUCIAL: do NOT release the previous scene's assets here. If we
  # did, then re-entered while still decoding, we'd lose the
  # previous scene's refcounts permanently (the previous scene is
  # already torn down by the first detour to loading_scene).
  if not catalog.allReady(target.manifest.assets):
    if active_scene != loading_scene:
      previous = active_scene
      setSceneAtomic(loading_scene)
      # Release the OUTGOING gameplay scene's assets exactly once,
      # at the moment we leave it for the loading scene. Shared
      # assets stayed alive because we acquired the target first.
      for asset in previous.manifest.assets:
        catalog.release(asset)
    return

  # Target is ready → swap and clear the pending marker. No release
  # call here — the previous gameplay scene's release already
  # happened at the loading-scene detour above. The loading scene
  # itself is eager-preloaded; its manifest is never released.
  setSceneAtomic(target)
  pending_target = null
```

The "loading scene" is just a regular scene with its own (small, eager) manifest — see the example below. Eager loading means its manifest is preloaded at `Game.init` time, so swapping into it never blocks.

**Failure case:** if any of `target.manifest.assets` ends in `.failed`, the loop above would spin forever. The `setScene` impl additionally checks `catalog.anyFailed(target.manifest.assets)` and aborts the transition (per the configurable failure policy, Open Questions §3) — this releases the target's acquired refcounts via `errdefer` to avoid a leak symmetrical to the sync-shim case.

### 4. Scene file — `assets:` block

Add to `scene.jsonc`:

```jsonc
{
  "assets": ["background", "ship", "rooms"],
  "entities": [ … ]
}
```

Optional. Omitted = no preload, scripts manage manually (legacy path). Each name must match a resource declared in `project.labelle` — the assembler validates this at build time, see §5 below.

### 5. labelle-assembler — manifest emission + validation

Three changes:

1. **Collect manifests.** When parsing each scene `.jsonc`, read the `assets:` array. Emit a comptime map: `scene_name → []const []const u8`. The engine reads this map in `setScene` and stores it on `SceneEntry.assets` (a new field added in Phase 2).
2. **Validate names.** Every entry in an `assets:` block must match a resource declared in the top-level `project.labelle` `resources` array. Unknown names → hard build error with a "did you mean…" suggestion based on Levenshtein distance against the known set. This is the typo-detection guard: `"asset"` vs `"assets"` would be caught by an unknown-key check on the scene file itself.
3. **Switch lazy default.** `lazy: true` on a `project.labelle` resource becomes the default. Resources that no scene declares fall back to eager registration (back-compat for projects that don't migrate to manifests).

### 6. Audio + font loaders (stubs)

Stub `audio.zig` and `font.zig` register a vtable whose `decode()` returns `error.LoaderNotImplemented`. The error flows through the standard `pump()` failure path: entry transitions to `.failed`, `lastError` returns the error, `setScene` aborts with it (or warns, per Open Questions #3). Crucially, **no panics** — a typo'd manifest entry cannot crash the process; it produces a localised, debuggable error.

The registration / queue / pump path is exercised end-to-end by the stubs, so when real `decodeAudio` / `decodeFont` loaders land in their own RFCs, they only need to provide the vtable functions — no streaming machinery work.

## Example: FP loading screen, post-RFC

```jsonc
// scenes/loading.jsonc
{
  "assets": ["loading_bar"],   // tiny, eager-preloaded at Game.init
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
    const target = game.scenes.get("main");      // SceneEntry, with `.assets` field added in Phase 2
    state.bar_scale = game.assets.progress(target.assets);
    if (game.assets.allReady(target.assets)) game.setScene("main");
}
```

The bar animates because decode is on the worker thread and the loading scene's own assets are already ready. Scene transition is automatic on completion. No manual `loadAtlasIfNeeded` calls anywhere.

## Migration plan

1. **Phase 1 — primitives:**
   - Add `gfx.decodeImage` / `gfx.uploadTexture` (sokol + raylib + mock).
   - Add `AssetCatalog`, `AssetWorker`, `image` loader, audio/font stubs.
   - `loadAtlasFromMemory` and `loadAtlasIfNeeded` become pump-driven sync shims (see §2).
   - **No UX change yet:** the sync shims still block the main thread, so the cold-start freeze on FP is unchanged. This phase exists to land the plumbing without touching any caller. CI green, no behavior change visible to projects.

2. **Phase 2 — scene manifests (the cold-start win):**
   - Scene loader gains `scene_assets_acquire/release` hooks; `setScene` calls them in acquire-new-then-release-old order.
   - Assembler reads `assets:` blocks, validates against `project.labelle`, emits the per-scene asset map onto `SceneEntry.assets`.
   - FP migrates `main.jsonc` and `loading.jsonc`. The loading bar finally animates because the wait happens *between* scenes, not *inside* a frame.

3. **Phase 3 — refcount unload:**
   - Catalog frees ready assets (via `loader.free`) when refcount hits zero.
   - Validate against FP (it has only one main scene, so unload mostly happens at shutdown, but the codepath is exercised when shaders/UI swap atlases in/out).

4. **Phase 4 — audio + font loaders:**
   - Real `decodeAudio` / `decodeFont` implementations replace the stubs; one follow-up RFC per format.

Each phase ships as its own PR set across `labelle-gfx`, `labelle-engine`, `labelle-assembler`. Phases 1 + 2 together deliver the cold-start win; 3 and 4 are quality-of-life follow-ups that don't touch the streaming machinery.

## Open questions

1. **Worker pool vs single thread.** Single thread is simpler and enough for FP. If a project ever needs to load 50+ atlases in parallel during a loading screen, we'd want a small fixed-size pool. Defer until profiling shows contention.
2. **Upload throttle (`UPLOAD_BUDGET_PER_FRAME`).** Starting value of 4 is a guess; needs measurement on the Galaxy Tab to confirm it doesn't hitch.
3. **Failure policy at `setScene` time.** Should a `.failed` asset abort the transition, or let the scene tick with the asset missing? Current proposal: configurable via a `Game.asset_failure_policy` enum (`fatal` | `warn` | `silent`), default `fatal`. Stub loaders use the same path, so a typo'd audio entry produces a hard error in dev.
4. **Scene-as-asset.** Should scene `.jsonc` themselves go through the catalog? Symmetrically clean, but they're tiny and eager-load from `@embedFile` is fine. Punt unless a real need shows up.
5. **`acquire` from non-main threads.** v1 makes the catalog single-threaded (acquire/release on main). Worker only touches its own queue. If scripts ever run on worker threads (they don't today), revisit.
6. **SPSC ring buffer sizing.** Both queues are bounded. If `register()` is called more times than the ring can hold before `pump()` drains, we'd block on enqueue. Initial size 64 covers FP's 6 atlases × loading-screen burst with room to spare; revisit if a project hits the ceiling.
7. **Retry policy for `.failed` assets.** A decode/upload failure leaves the entry in `.failed` so callers can surface the error. But if the cause was transient (out of GPU memory during a spike, transient driver hiccup), the entry would block all future loads of the same asset. v1 exposes a manual `resetFailed(name)` so the sync shim and scene loader can opt into automatic retry; v2 might auto-rewind on refcount-to-zero, mirroring the `.ready` unload path.
8. **`acquire` enqueue overflow behaviour.** If the worker request ring is full (a burst that exceeds budget §6), `acquire` should return `error.QueueFull` rather than silently dropping the request. Callers handle the error explicitly: the sync shim retries after a `pump()`; the scene loader treats it like decode failure. Silently dropping was the bug that made an early prototype hang in `loadAtlasIfNeeded` — never let `acquire` succeed when the work didn't enqueue.
