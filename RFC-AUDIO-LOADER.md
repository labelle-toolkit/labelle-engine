# RFC: Audio Loader — Phase 4 of Asset Streaming

**Status:** Draft
**Author:** Alexandre
**Date:** 2026-04-17
**Tracking issue:** [#447](https://github.com/labelle-toolkit/labelle-engine/issues/447)
**Parent RFC:** [RFC-ASSET-STREAMING](./RFC-ASSET-STREAMING.md) §Phase 4

## Problem

Phases 1–3 of Asset Streaming shipped the catalog, worker, image loader, scene manifest wiring, and `scene_assets_acquire`/`scene_assets_release` hooks. Audio today is a stub: `src/assets/loaders/audio.zig` registers a vtable whose `decode`/`upload` return `error.NotImplemented`. Games cannot put sound effects or music in a scene's `assets:` block — the attempt produces a hard error via the existing Phase 2 failure path.

This RFC closes that gap: a real `decodeAudio` / `uploadSound` / `freeSound` implementation reachable through the same `AssetCatalog` API that already handles images.

## Goals

1. **Format coverage.** At minimum WAV (uncompressed) and OGG Vorbis (compressed, patent-clear). MP3 deferred — patent situation is clearer than it once was but still not as simple as Vorbis, and the available single-header decoders are larger.
2. **One asset → one device handle.** The catalog's refcount-and-unload machinery already works for discrete resources. Audio samples that a scene declares under `assets:` get decoded on the worker, handed to the audio device on the main thread, surfaced as a `SoundId`, and freed when refcount hits zero.
3. **Same backend-hook pattern as images.** The engine does not import the audio backend directly. The assembler injects a `AudioBackend` function-pointer struct at `Game.init`, identical in shape to `ImageBackend`.
4. **No panics on bad data.** Decode errors flow through `entry.last_error` → `.failed` state → `setScene` consults `asset_failure_policy` (just shipped in #444). A corrupt OGG cannot crash the process; it produces a localised, debuggable failure.

## Non-goals

- **Streamed music.** Long tracks played via `MusicId` stream from disk/ROM directly through the audio backend; they are not discrete resources that benefit from catalog refcounting. They stay on the existing `AudioInterface` path. If the buffer size for a sound effect exceeds some threshold, that's a game-code concern, not an engine boundary.
- **3D / spatial audio.** Positional audio is a runtime concern on top of loaded buffers — orthogonal to the loader.
- **Multi-channel mixing, DSP, effect graphs.** Runtime concerns handled by the audio backend (raylib, sokol_audio, wgpu_audio), not by the asset system.
- **Resampling / channel conversion.** Decoded buffers are handed to the backend at their native rate/channel count. The backend already handles device-rate conversion per sample during playback.

## Design

### 1. Decoder selection

Single-header C decoders, statically linked into the backend:

- **WAV** → `dr_wav` (public domain, single header, handles PCM + IEEE float + common compressed formats)
- **OGG Vorbis** → `stb_vorbis` (Sean Barrett, public domain, single header, standard in the single-header ecosystem)

Dispatch happens in the backend's `decode` adapter based on `file_type`:

```zig
// assembler-side adapter, forwarded to engine via AudioBackend
fn decode(file_type: [:0]const u8, data: []const u8, allocator: Allocator) anyerror!DecodedAudio {
    if (std.mem.eql(u8, file_type, "wav")) return decodeWav(data, allocator);
    if (std.mem.eql(u8, file_type, "ogg")) return decodeOgg(data, allocator);
    return error.UnsupportedAudioFormat;
}
```

File type comes from the resource's filename extension at assembler codegen time — the same way `.png` drives the image loader today.

### 2. `DecodedAudio` — worker-thread payload

Sample format is **signed 16-bit interleaved PCM** at the decoder's native sample rate. Rationale:

- Both backends (raylib `LoadSoundFromWave`, sokol_audio's `saudio_push`) accept int16 PCM directly.
- 16-bit matches the WAV default and is the most common Vorbis decode target.
- Float32 doubles the memory footprint for no audible benefit on mobile-class output.

```zig
// engine-side plain POD — parallels DecodedImage in image.zig
pub const DecodedAudio = struct {
    samples: []i16,     // interleaved PCM, allocator-owned
    sample_rate: u32,   // 22050, 44100, 48000, …
    channels: u8,       // 1 = mono, 2 = stereo
};
```

### 3. `AudioBackend` — runtime hook struct

Mirrors `ImageBackend` exactly. Engine never imports the audio crate; the assembler injects adapters at `Game.init`.

```zig
pub const SoundId = u32;  // opaque backend handle, parallels Texture

pub const AudioBackend = struct {
    decode: *const fn (
        file_type: [:0]const u8,
        data: []const u8,
        allocator: Allocator,
    ) anyerror!DecodedAudio,

    /// Main-thread: hand the PCM buffer to the audio device, return
    /// an opaque SoundId. Backend COPIES the samples — the caller
    /// frees `decoded.samples` after this returns.
    upload: *const fn (decoded: DecodedAudio) anyerror!SoundId,

    /// Main-thread: release the device-side buffer.
    unload: *const fn (sound: SoundId) void,
};

pub fn setBackend(backend: AudioBackend) void { ... }
pub fn clearBackend() void { ... }  // test teardown
```

Ownership of `samples`: same contract as `pixels` in the image loader. Worker allocates through the allocator; `upload` copies to the backend device, then `loader.upload` frees the buffer via the same allocator (see image loader's docstring). `backend.upload` does NOT take ownership — documented in one place (the struct comment) and mirrored across the image side so the two loaders stay isomorphic.

### 4. Wiring into `DecodedPayload` / `UploadedResource`

Both unions already declare an `audio:` variant as a placeholder (empty struct). Phase 4 fills them in:

```zig
// src/assets/loader.zig — existing placeholders replaced

pub const DecodedPayload = union(LoaderKind) {
    image: struct { pixels: []u8, width: u32, height: u32 },
    audio: audio_loader.DecodedAudio,   // was: struct {}
    font: struct {},                    // still placeholder, see #448
};

pub const UploadedResource = union(LoaderKind) {
    image: Texture,
    audio: audio_loader.SoundId,        // was: struct {}
    font: struct {},                    // still placeholder, see #448
};
```

The type-erased `DecodedPayload` / `UploadedResource` mean the catalog, pump, and hooks code stay unchanged — the Phase 1 scaffolding already anticipated this.

### 5. `audio.zig` — real vtable

Replaces the three `error.NotImplemented` stubs:

```zig
fn decode(file_type: [:0]const u8, data: []const u8, allocator: Allocator) anyerror!DecodedPayload {
    const backend = active_backend orelse return error.AudioBackendNotSet;
    const out = try backend.decode(file_type, data, allocator);
    return .{ .audio = out };
}

fn upload(entry: *AssetEntry, decoded: DecodedPayload, allocator: Allocator) anyerror!void {
    const backend = active_backend orelse return error.AudioBackendNotSet;
    const sound = try backend.upload(decoded.audio);
    entry.resource = .{ .audio = sound };
    allocator.free(decoded.audio.samples);
}

fn drop(allocator: Allocator, decoded: DecodedPayload) void {
    allocator.free(decoded.audio.samples);
}

fn free(entry: *AssetEntry) void {
    const backend = active_backend orelse return;
    const sound = switch (entry.resource.?) { .audio => |s| s, else => unreachable };
    backend.unload(sound);
    entry.resource = null;
}
```

Direct structural analogue of `image.zig`. The only novelty is the sample-buffer free instead of pixel-buffer free. `drop` and `free` split for the same reason image has them split — refcount-zero-mid-decode vs refcount-zero-at-ready.

### 6. Asset manifest format — extension-driven

Assembler codegen (ticket deferred to the assembler side, but noted here) reads the extension of each resource's path and dispatches to the right `register` call:

- `.png` / `.jpg` → `catalog.register(name, .image, ext, bytes)`
- `.wav` / `.ogg` → `catalog.register(name, .audio, ext, bytes)`
- `.ttf` / `.otf` → `catalog.register(name, .font, ext, bytes)` (deferred to #448)

Unknown extensions are a hard error at assembler generation time. The game-side API is unchanged:

```jsonc
// scenes/boss_arena.jsonc
{
  "assets": ["boss_theme", "boss_roar", "arena_floor"]
}
```

No loader kind in the manifest — the resource entry in `project.labelle` already carries the file path, so the extension is known at codegen time.

### 7. Testing strategy

- **Unit**: `test/audio_loader_test.zig`. Mock `AudioBackend` injects a `decode` that returns a fixed PCM buffer from a hand-built "fake-wav" input; `upload` returns a sentinel `SoundId`; `unload` increments a counter. Round-trip: register → acquire → pump → assert `.ready` and sentinel resource → release → assert unload called and `.registered` state. Mirrors the existing image test at `src/assets/catalog.zig:711`.
- **Integration**: extend `test/asset_catalog_test.zig` with a two-type scene manifest (image + audio). Proves `DecodedPayload.audio` and `UploadedResource.audio` thread through without collision.
- **Failure path**: malformed bytes → `decode` returns `error.CorruptVorbis` → pump transitions to `.failed` → `setScene` consults `asset_failure_policy` (tested in #444 — reuses that path).
- **No real WAV / OGG bytes in the engine test** — those come in the backend-side tests (raylib-audio, sokol-audio) where real decoders are linked.

### 8. Migration / compatibility

- The existing synchronous audio API (`Game.playSound(id)`, `Game.stopSound(id)`, `game.audio.load*` if any) keeps working. Games that bypass the catalog can still pre-load sounds the old way.
- Scenes that add audio entries to their `assets:` block automatically get the streaming path — no opt-in flag.
- `asset_failure_policy = .warn` means a corrupt sound doesn't block the scene; the game gets a silent `SoundId` (or the default — backend-dependent). Covered by the policy tests from #444.

## Migration plan

Three landable commits, each green.

1. **Engine side — types + vtable.** Flesh out `DecodedPayload.audio` / `UploadedResource.audio` to real types, replace the three stubs in `audio.zig` with real-vtable bodies, add the module-level backend slot + `setBackend` / `clearBackend`. Add the unit test with a mock backend. CI green because no real decoder links — the backend hook is test-injected.
2. **Assembler side — file-type dispatch + codegen.** Assembler recognises `.wav` / `.ogg` extensions, emits `catalog.register(name, .audio, ext, bytes)` calls in generated `main.zig`. Unsupported extensions become a generate-time error. This PR is engine-unaware; it just plugs the right arguments into existing catalog calls.
3. **Backend side — raylib-audio + sokol-audio adapters.** Each backend pulls `dr_wav` + `stb_vorbis`, implements `decodeWav` / `decodeOgg`, registers via `audio_loader.setBackend`. One PR per backend. Third-party backends (sdl, bgfx, wgpu) can follow at their own pace — the engine ships with `AudioBackendNotSet` as a legitimate early state for backends that haven't wired the hook yet.

## Open questions

1. **Should `decode` produce a single canonical sample format (e.g. int16 @ 44100 Hz stereo), or preserve the source rate/channels and defer conversion to the backend?** Proposal above says "preserve source". Backends that need canonical format can do the resample in their own `upload` adapter. Rationale: the catalog is format-agnostic — the same buffer shouldn't be re-resampled if different backends want different rates.

2. **Unified memory budget across catalog entries?** Audio buffers can be large (a 60-second stereo OGG at 44.1 kHz int16 = ~10 MB decoded). Today the catalog tracks refcount but not byte size. Proposal: add `entry.decoded_bytes: usize` to `AssetEntry`, populated by loaders, queryable via `catalog.totalDecodedBytes()`. Out of scope for this RFC — file as a follow-up issue if a game hits a memory ceiling.

3. **Music streaming seam.** This RFC excludes streamed music on the grounds that it's a different lifecycle. But scenes might still want to declare `"background_music"` in their `assets:` list for readability even when it streams. Options:
   - **a.** Strict separation: scenes reference streamed music via a different mechanism (`scene.jsonc` `music:` field, parallel to `assets:`).
   - **b.** Unify: streamed music is a third `LoaderKind` (`music`), its `upload` hands back a `MusicId`, its `drop`/`free` close the stream handle. Refcount-1 because music rarely overlaps scenes.
   - Leaning **a** — streaming and loading are different enough lifecycles that sharing the catalog creates more confusion than it saves.

## References

- [RFC-ASSET-STREAMING §Phase 4](./RFC-ASSET-STREAMING.md#migration-plan) — parent RFC migration plan step 4.
- `src/assets/loaders/image.zig` — reference implementation this RFC mirrors.
- `src/assets/loader.zig` — `DecodedPayload` / `UploadedResource` / `AssetLoaderVTable` shared types.
- `src/assets/catalog.zig` — refcount + pump + failure path (unchanged by this RFC).
- `src/audio_types.zig` — existing `SoundId` / `MusicId` (opaque handles used by the runtime audio interface, distinct from the `SoundId` this RFC adds to `UploadedResource`; the opaque handle type is what flows through the catalog).
- [dr_wav](https://github.com/mackron/dr_libs) — proposed WAV decoder (public domain, single header).
- [stb_vorbis](https://github.com/nothings/stb) — proposed OGG decoder (public domain, single header).
- #444 (just shipped) — `scene_assets_acquire` / `scene_assets_release` hooks and `asset_failure_policy`; audio assets inherit this wiring unchanged.
- #448 — font loader (sibling Phase 4 RFC, not yet drafted).
