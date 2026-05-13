# RFC: Font Loader — Phase 4 of Asset Streaming

**Status:** Draft
**Author:** Alexandre
**Date:** 2026-05-13
**Tracking issue:** [#448](https://github.com/labelle-toolkit/labelle-engine/issues/448)
**Parent RFC:** [RFC-ASSET-STREAMING](./RFC-ASSET-STREAMING.md) §Phase 4
**Sibling RFC:** [RFC-AUDIO-LOADER](./RFC-AUDIO-LOADER.md) ([#447](https://github.com/labelle-toolkit/labelle-engine/issues/447))

## Problem

Phases 1–3 of Asset Streaming shipped the catalog, worker, image loader, scene manifest wiring, and `scene_assets_acquire`/`scene_assets_release` hooks. Fonts today are a stub: `src/assets/loaders/font.zig` registers a vtable whose `decode`/`upload` return `error.NotImplemented`. Games cannot put a TTF or OTF in a scene's `assets:` block.

The hole is wider for fonts than for audio. Audio at least has a runtime surface (`AudioInterface`, `SoundId`, `MusicId`) — Phase 4 is "swap the decoder in". Fonts have **nothing**: `gui_types.zig` exposes `font_size: f32` on labels and labels render through the GUI backend's default font. There is no `FontId`, no glyph atlas, no metrics struct, no engine-side typography surface. Phase 4 introduces fonts as a first-class asset and threads them through the same `AssetCatalog` machinery that already handles images.

This RFC closes the loader-side gap: a real `decodeFont` / `uploadFontAtlas` / `freeFontAtlas` implementation reachable through the same `AssetCatalog` API that already handles images and (per [#447](./RFC-AUDIO-LOADER.md)) audio.

## Goals

1. **Format coverage.** TrueType (`.ttf`) and OpenType (`.otf`) — both decoded by the same single-header library (`stb_truetype`). Variable fonts, CFF/PostScript outlines, and bitmap-only fonts deferred.
2. **One asset → one baked atlas + metrics bundle.** The catalog's refcount-and-unload machinery already works for discrete resources. A font resource the scene declares under `assets:` gets parsed + rasterised on the worker, the bitmap handed to the GPU backend as a texture on the main thread, surfaced as a `FontId`, and freed when refcount hits zero.
3. **Same backend-hook pattern as images and audio.** The engine does not import the rasterise/upload backend directly. The assembler injects a `FontBackend` function-pointer struct at `Game.init`, identical in shape to `ImageBackend` and `AudioBackend`.
4. **No panics on bad data.** Decode errors flow through `entry.last_error` → `.failed` state → `setScene` consults `asset_failure_policy` (shipped in #444). A corrupt TTF cannot crash the process; it produces a localised, debuggable failure.

## Non-goals

- **Runtime glyph layout / shaping.** Bidi, complex script shaping (Arabic, Indic), ligature substitution — those belong in a layout layer (HarfBuzz-class) on top of loaded atlases. Phase 4 produces the *glyph data*; shaping is the renderer's job.
- **Distance-field (SDF / MSDF) atlases.** Deferred. The first cut bakes plain 8-bit alpha bitmaps because that's what `stb_truetype_BakeFontBitmap` produces with zero extra dependencies. SDF can land as a second `decode` variant once a real use case appears (UI text zoom, world-space text). Open question §1.
- **Dynamic glyph atlas growth.** Atlases are baked at a fixed size and glyph set at acquire time. No "missing glyph fault → rebake" path. If a game needs a wider glyph set, declare a second font resource — refcounting handles the rest.
- **Hinting / sub-pixel positioning.** Plain 8-bit greyscale at integer pixel positions. Hinting is a `stb_truetype` flag that can be toggled in a follow-up if rendering quality demands it.
- **Font fallback chains.** One asset = one face. If a glyph isn't in the baked atlas, the renderer draws nothing (or `?` — backend-defined). Fallback is a renderer concern.
- **Kerning beyond what `stb_truetype` exposes.** `stbtt_GetCodepointKernAdvance` returns the simple GPOS kern pairs; we surface that. GPOS positioning tables beyond pairs are out of scope.

## Design

### 1. Decoder selection

Single-header C decoder, statically linked into the backend:

- **TTF / OTF** → `stb_truetype` (Sean Barrett, public domain, single header, the standard pick across the single-header ecosystem and what raylib's `LoadFont` already wraps).

Both extensions dispatch to the same decoder path:

```zig
// backend-side adapter, forwarded to engine via FontBackend
fn decode(file_type: [:0]const u8, data: []const u8, params: FontBakeParams, allocator: Allocator) anyerror!DecodedFont {
    if (std.mem.eql(u8, file_type, "ttf") or std.mem.eql(u8, file_type, "otf")) {
        return bakeWithStbTruetype(data, params, allocator);
    }
    return error.UnsupportedFontFormat;
}
```

File type comes from the resource's filename extension at assembler codegen time — the same way `.png` drives the image loader and `.wav` / `.ogg` drive the audio loader.

### 2. Bake parameters — the new dimension

Images and audio are decoded with no parameters: the source bytes fully determine the output. **Fonts aren't.** The same TTF baked at 16 px and 32 px is two different atlases; the same TTF baked for ASCII vs Latin-1 is two different atlases. The loader needs `FontBakeParams` alongside the source bytes:

```zig
pub const FontBakeParams = struct {
    /// Pixel height (cap-height-ish — passed straight to
    /// stbtt_ScaleForPixelHeight). f32 because stb_truetype takes f32.
    pixel_height: f32 = 16,

    /// Codepoint ranges to bake. Half-open [first, last).
    /// Default = ASCII printable (0x20..0x7F).
    ranges: []const CodepointRange = &.{ .{ .first = 0x20, .last = 0x7F } },

    /// Atlas dimensions. 512×512 fits ASCII at up to ~48 px with
    /// stbtt_PackBegin's default oversample. Project can override.
    atlas_width: u32 = 512,
    atlas_height: u32 = 512,
};

pub const CodepointRange = struct { first: u32, last: u32 };
```

Where do these come from? **The manifest entry, via the assembler.** `project.labelle` resource entries for fonts gain optional `pixel_height` / `ranges` / `atlas_size` fields; the assembler embeds them into the generated `catalog.register` call. The default (16 px, ASCII, 512×512) covers the common case — UI labels in `gui_types.zig` already default to `font_size: f32 = 16`.

Same-TTF-different-params produces distinct catalog entries — refcounting key includes the params hash. Open question §3 covers the cache-key shape.

### 3. `DecodedFont` — worker-thread payload

The worker outputs:

```zig
// engine-side plain POD — parallels DecodedImage in image.zig
pub const DecodedFont = struct {
    /// 8-bit alpha bitmap, allocator-owned.
    bitmap: []u8,
    width: u32,
    height: u32,

    /// One entry per baked codepoint, addressed by glyphIndex(cp).
    glyphs: []Glyph,

    /// Lookup: codepoint → index into `glyphs`. Sorted by codepoint
    /// for binary search; renderer hot path uses this every glyph.
    /// Built from `FontBakeParams.ranges` at bake time.
    codepoint_index: []const CodepointEntry,

    /// Vertical metrics, in pixels at the baked size.
    ascent: f32,
    descent: f32,    // negative (below baseline)
    line_gap: f32,
    line_height: f32, // ascent - descent + line_gap, precomputed

    /// Kerning pairs (sparse). Empty slice if disabled / no GPOS kern.
    kerning: []const KernPair,
};

pub const Glyph = struct {
    /// UV rect in the atlas, in *pixels* (not normalised).
    u0: u16, v0: u16, u1: u16, v1: u16,

    /// Pen-relative blit offset and advance, in pixels.
    xoff: f32, yoff: f32, advance: f32,
};

pub const CodepointEntry = struct { codepoint: u32, glyph_index: u32 };

pub const KernPair = struct { first: u32, second: u32, advance: f32 };
```

Why this shape:

- **8-bit alpha, not RGBA.** Fonts modulate against a draw colour at render time. RGBA would 4× the bandwidth for no benefit. The backend can expand to a single-channel GL_R8 / `.r8` sokol texture on upload, or expand to RGBA there if the GPU pipeline doesn't support single-channel sampling.
- **Pixel-space UVs.** Renderers normalise at draw time. Keeping integer pixel rects in the payload makes the bake output reproducible across atlas sizes and easier to debug visually.
- **Pen-relative offsets pre-baked.** `xoff` / `yoff` already incorporate the glyph's bearing — the renderer just adds them to the pen position. Same shape as `stb_truetype`'s `aligned_quad` output.
- **Codepoint index separate from `glyphs`.** Renderers look up by codepoint (`'A' = 0x41`); the glyph array is dense (zero-indexed). The separate lookup lets the bake step pack glyphs without leaving gaps for unused codepoints.

### 4. `FontBackend` — runtime hook struct

Mirrors `ImageBackend` and `AudioBackend`. Engine never imports the typography crate; the assembler injects adapters at `Game.init`.

The handle the backend returns is a new `font_types.FontId` (`{ index: u16, generation: u16 }`), declared in `src/font_types.zig` parallel to `audio_types.zig`. Reasoning matches the audio RFC's stance on `SoundId`: a single canonical handle type owned at engine level, not a loader-scoped one.

```zig
const font_types = @import("font_types.zig");  // new module, Phase 4

pub const FontBackend = struct {
    decode: *const fn (
        file_type: [:0]const u8,
        data: []const u8,
        params: FontBakeParams,
        allocator: Allocator,
    ) anyerror!DecodedFont,

    /// Main-thread: upload the alpha bitmap to a GPU texture, return
    /// a `FontId`. Backend COPIES the bitmap and glyph tables — the
    /// caller frees `decoded.bitmap` / `decoded.glyphs` /
    /// `decoded.codepoint_index` / `decoded.kerning` after this
    /// returns.
    upload: *const fn (decoded: DecodedFont) anyerror!font_types.FontId,

    /// Main-thread: release the GPU texture and any backend-side
    /// glyph metadata.
    unload: *const fn (font: font_types.FontId) void,
};

pub fn setBackend(backend: FontBackend) void { ... }
pub fn clearBackend() void { ... }  // test teardown
```

Ownership of `bitmap` / `glyphs` / `codepoint_index` / `kerning`: same contract as `pixels` in the image loader and `samples` in audio. Worker allocates through the allocator; `upload` copies whatever it needs into backend-owned storage; `loader.upload` frees all four slices via the same allocator after `backend.upload` returns. `backend.upload` does NOT take ownership — documented once on the struct comment and mirrored across image / audio / font for consistency.

**Why the backend owns glyph metadata too, not just the texture.** Renderers look up glyphs hundreds of times per frame. Cloning the glyph/codepoint/kern tables once into backend-owned memory at upload time avoids a per-frame indirection through the catalog. Backends that prefer to keep the metadata engine-side can do so by returning a `FontId` that simply indexes back into engine-held tables; the contract leaves this open. The exposed query surface (see §6) goes through the backend regardless.

### 5. Wiring into `DecodedPayload` / `UploadedResource`

Both unions already declare a `font:` variant as a placeholder (empty struct). Phase 4 fills them in **inline** inside `src/assets/loader.zig`, mirroring the audio RFC's choice:

```zig
// src/assets/loader.zig — existing placeholders replaced

pub const DecodedPayload = union(LoaderKind) {
    image: struct { pixels: []u8, width: u32, height: u32 },
    audio: struct {                  // from #447
        samples: []i16,
        sample_rate: u32,
        channels: u8,
    },
    font: struct {
        bitmap: []u8,
        width: u32,
        height: u32,
        glyphs: []Glyph,
        codepoint_index: []const CodepointEntry,
        ascent: f32,
        descent: f32,
        line_gap: f32,
        line_height: f32,
        kerning: []const KernPair,
    },
};

pub const UploadedResource = union(LoaderKind) {
    image: Texture,
    audio: audio_types.SoundId,   // from #447
    font: font_types.FontId,      // new in this RFC
};
```

**Why inline instead of `font_loader.DecodedFont`.** Same circular-import argument the audio RFC makes: `src/assets/loaders/font.zig` imports `../loader.zig`; pointing the parent back at the child cycles the dependency. Keep the payload inline and reuse the engine-owned `font_types.FontId` rather than minting a loader-scoped one. The `font_loader.DecodedFont` alias can still exist in `src/assets/loaders/font.zig` as a convenience for backend adapters, but it's a type alias, not the canonical definition.

The type-erased `DecodedPayload` / `UploadedResource` mean the catalog, pump, and hooks code stay unchanged — Phase 1's scaffolding already anticipated this.

### 6. `font.zig` — real vtable

Replaces the three `error.NotImplemented` stubs:

```zig
fn decode(file_type: [:0]const u8, data: []const u8, allocator: Allocator) anyerror!DecodedPayload {
    const backend = active_backend orelse return error.FontBackendNotSet;
    // params are carried alongside the entry — see §7
    const params = pendingBakeParamsFor(entry_id);
    const out = try backend.decode(file_type, data, params, allocator);
    return .{ .font = out };
}

fn upload(entry: *AssetEntry, decoded: DecodedPayload, allocator: Allocator) anyerror!void {
    const backend = active_backend orelse return error.FontBackendNotSet;
    const font = try backend.upload(decoded.font);
    entry.resource = .{ .font = font };
    allocator.free(decoded.font.bitmap);
    allocator.free(decoded.font.glyphs);
    allocator.free(decoded.font.codepoint_index);
    allocator.free(decoded.font.kerning);
}

fn drop(allocator: Allocator, decoded: DecodedPayload) void {
    allocator.free(decoded.font.bitmap);
    allocator.free(decoded.font.glyphs);
    allocator.free(decoded.font.codepoint_index);
    allocator.free(decoded.font.kerning);
}

fn free(entry: *AssetEntry) void {
    const resource = entry.resource orelse return;
    // Mirrors image.zig / audio.zig: if the backend was cleared
    // (e.g. test teardown via `clearBackend`) after the asset
    // uploaded, skip the `unload` call but STILL clear
    // `entry.resource` — callers that check `entry.resource != null`
    // as a cleanup-completed flag rely on that invariant (see the
    // "loader.free contract" comment in `src/assets/loader.zig`).
    if (active_backend) |backend| switch (resource) {
        .font => |font| backend.unload(font),
        else => {},
    };
    entry.resource = null;
}
```

Direct structural analogue of `image.zig` and `audio.zig`. The novelty is the multi-slice free instead of single-buffer free, and the bake-params lookup discussed in §7.

### 7. Bake params delivery — the one place fonts diverge

Image / audio loaders need only `(file_type, bytes)` to decode. Fonts also need `FontBakeParams`. The worker only carries a `WorkRequest` snapshot, which today is `(entry_id, loader_vtable, bytes, file_type)`. Two reasonable wirings, both reviewed in Open Questions §4:

- **Option A (preferred): extend `WorkRequest`.** Add a borrowed `params: *const anyopaque` field carrying a pointer to loader-specific bake params. The catalog stores params in `AssetEntry` at `register` time (image/audio store `null`). Worker passes the pointer through; font loader casts to `*const FontBakeParams`. Same lifetime as the bytes — params live as long as the entry.
- **Option B: catalog reaches back.** Worker enqueues result with placeholder; pump notices `LoaderKind == .font` and re-decodes on the main thread with the params it can fetch from the entry. Defeats the off-thread bake — rejected.

Going with Option A. One field on `WorkRequest`, type-erased, opt-in per loader.

### 8. Asset manifest format — extension + per-resource params

Assembler codegen reads the extension and the optional font-specific fields:

- `.png` / `.jpg` → `catalog.register(name, .image, ext, bytes)`
- `.wav` / `.ogg` → `catalog.register(name, .audio, ext, bytes)` (#447)
- `.ttf` / `.otf` → `catalog.registerFont(name, ext, bytes, params)`

A separate `registerFont` (rather than overloading `register` with an extra arg) keeps the image/audio sites unchanged. The catalog stores `params` into the entry; the worker reads it via the §7 `WorkRequest.params` field.

`project.labelle` resource entry shape (assembler-side change, sketched here for completeness):

```zig
.resources = .{
    .{ .name = "ui_font", .path = "fonts/m5x7.ttf", .lazy = true,
       .font = .{ .pixel_height = 16, .atlas_size = .{ 512, 512 } } },
    .{ .name = "title_font", .path = "fonts/m5x7.ttf", .lazy = true,
       .font = .{ .pixel_height = 48, .atlas_size = .{ 1024, 1024 },
                  .ranges = &.{ .{ 0x20, 0x7F }, .{ 0xA0, 0x100 } } } },
},
```

Scene `.jsonc` is unchanged — just names:

```jsonc
// scenes/title.jsonc
{
  "assets": ["ui_font", "title_font", "title_background"]
}
```

Two registrations of the same TTF path with different params are two catalog entries (different `name`), each with its own atlas. Refcounting works per-entry, which is the right granularity.

### 9. GUI integration — minimum viable surface

Phase 4 only delivers the *loader*. The GUI consuming it is a separate ticket (file follow-up #TBD). To avoid leaving fonts inert, this RFC adds the minimal connective tissue:

- `gui_types.Label` gains an optional `font: ?[]const u8 = null` field (asset name). Null = backend default font (current behaviour). Non-null = look up via `game.assets.get(name).font` resource handle.
- The GUI mixin (`src/game/gui_mixin.zig`) at the label render site falls back to today's `font_size`-only path when `font == null`. When set, it passes the `FontId` to the backend's text draw call.
- No new public render API on the engine side — the backend's existing text-draw entrypoint gains a `?FontId` parameter.

This is small enough to land in the same PR set as the loader. Anything bigger (rich text, multi-font runs, baseline alignment options) lives in the follow-up ticket.

### 10. Testing strategy

- **Unit**: `test/font_loader_test.zig`. Mock `FontBackend` injects a `decode` that returns a fixed bitmap + 3-glyph table from a hand-built "fake-ttf" input; `upload` returns a sentinel `FontId`; `unload` increments a counter. Round-trip: register → acquire → pump → assert `.ready` and sentinel resource → release → assert unload called and `.registered` state. Mirrors `audio_loader_test.zig` and the image test at `src/assets/catalog.zig:711`.
- **Bake params plumbing**: assert two registrations of the same path with different `pixel_height` produce two entries with different `.ready` resources, and that the worker received the right params via the §7 `WorkRequest` extension.
- **Integration**: extend `test/asset_catalog_test.zig` with a three-type scene manifest (image + audio + font). Proves all three `DecodedPayload` variants thread through without collision.
- **Failure path**: malformed bytes → `decode` returns `error.CorruptTTF` → pump transitions to `.failed` → `setScene` consults `asset_failure_policy` (#444 wiring, unchanged).
- **No real TTF bytes in the engine test** — those come in the backend-side tests (raylib-font, sokol-font) where `stb_truetype` is actually linked.

### 11. Migration / compatibility

- Existing labels with no `font:` field render through today's default-font path. No behaviour change unless a game opts in.
- Scenes that add font entries to their `assets:` block automatically get the streaming path — no opt-in flag.
- `asset_failure_policy = .warn` means a corrupt font doesn't block the scene; the label silently falls back to the default font. Covered by the policy tests from #444.

## Migration plan

Four landable commits, each green.

1. **Engine side — types + vtable.** Add `src/font_types.zig` (`FontId`). Flesh out `DecodedPayload.font` / `UploadedResource.font` to real types in `src/assets/loader.zig`. Add `Glyph` / `CodepointEntry` / `KernPair` / `FontBakeParams` to `src/assets/loaders/font.zig`. Replace the three stubs with real vtable bodies + module-level backend slot + `setBackend` / `clearBackend`. Add `WorkRequest.params` pass-through (§7). Add the unit test with a mock backend. CI green because no real `stb_truetype` links — the backend hook is test-injected.
2. **Engine side — GUI hook-up.** Add `font: ?[]const u8` to `gui_types.Label`. Wire the GUI mixin to resolve the asset and pass `FontId` to the backend text-draw call when set. Default-font path unchanged.
3. **Assembler side — file-type dispatch + codegen.** Assembler recognises `.ttf` / `.otf` extensions, reads per-resource `.font = .{ ... }` blocks from `project.labelle`, emits `catalog.registerFont(name, ext, bytes, params)` calls in generated `main.zig`. Unsupported extensions become a generate-time error. This PR is engine-unaware; it just plugs the right arguments into existing catalog calls.
4. **Backend side — raylib-font + sokol-font adapters.** Each backend pulls `stb_truetype`, implements `decodeFont` via `stbtt_BakeFontBitmap` (or `stbtt_PackBegin` for better packing), registers via `font_loader.setBackend`. One PR per backend. Third-party backends can follow at their own pace — the engine ships with `FontBackendNotSet` as a legitimate early state for backends that haven't wired the hook yet.

Steps 1 + 3 are the loader; step 2 is the minimum GUI surface so the loader is observably useful; step 4 is the per-backend wiring. The audio RFC (#447) lands in three steps because audio doesn't need the GUI hook.

## Open questions

1. **Bitmap vs SDF / MSDF atlases.** Plain 8-bit bitmaps are the v1 pick — `stbtt_BakeFontBitmap` is one function call. SDF gives clean scaling and rotation but adds either a build-time tool (`msdf-atlas-gen`) or a runtime distance-transform pass. Proposal: ship bitmap, file a follow-up that adds `.font_kind = .sdf` to `FontBakeParams` once a real use case appears.

2. **Default glyph range.** ASCII 32–126 covers FP and most of FP's labels. Latin-1 (32–255) adds ~128 glyphs with a negligible atlas cost and would be a friendlier default for European projects. Picking ASCII because (a) it matches what backends like raylib's `LoadFont` already use, (b) it keeps the default atlas at 512×512 even at 48 px, (c) opting in to Latin-1 is one line in `project.labelle`. Easy to revisit.

3. **Cache key shape.** Two `registerFont` calls with the same TTF path but different `pixel_height` are two entries today (different `name`). If two scenes both want `(m5x7.ttf, 16 px)` and declare different names for it, that's two atlases for the same bake — wasteful. Options:
   - **a.** Document the footgun, leave it to the project author. (Current proposal.)
   - **b.** Hash `(path, params)` as a secondary key; aliasing names share a single atlas.
   - **b** is cleaner but bleeds into the catalog's name-as-identity model. Defer until profiling shows duplicate atlases are a real cost.

4. **`WorkRequest.params` shape.** Type-erased `*const anyopaque` is the simplest. Alternatives: a tagged union over loader kinds (`union(LoaderKind) { image: void, audio: void, font: *const FontBakeParams }`), or per-loader-kind `WorkRequest` variants. Anyopaque wins on minimum diff to the catalog; the union variant might win on type safety if more loaders need params (e.g. a future shader loader with compile flags). Going with anyopaque, will revisit if a third params-carrying loader lands.

5. **Where the GUI consumes the loaded `FontId`.** §9 puts the `Label.font` field on `gui_types.Label` and resolution in the GUI mixin. Alternatives: a separate `TextRenderer` component, or pushing font resolution down into each backend's GUI adapter. The mixin path is closest to how `gui_types.Color` and `font_size: f32` work today; preferring it for consistency. If the GUI grows a real text-styling system later, this is a refactor target.

6. **Variable fonts and OpenType features.** `stb_truetype` doesn't support variable-font axes or rich OpenType features (small caps, stylistic sets). Out of scope for v1. Projects that need these can pre-render fixed instances and ship them as separate TTFs.

7. **Retina / high-DPI baking.** A 16 px font on a 2× display wants a 32 px atlas. Today the bake doesn't know the display scale. Options: (a) project declares the scaled size manually, (b) assembler reads a `display_scale` from the game's runtime context and multiplies. Picking (a) — the project knows its target devices better than the assembler. The renderer scales the quads back down at draw time so glyphs render at the requested logical size.

## References

- [RFC-ASSET-STREAMING §Phase 4](./RFC-ASSET-STREAMING.md#migration-plan) — parent RFC migration plan step 4.
- [RFC-AUDIO-LOADER](./RFC-AUDIO-LOADER.md) — sibling Phase 4 RFC (#447). This RFC mirrors its structure and borrows the inline-payload / backend-hook / sentinel-test conventions verbatim.
- `src/assets/loaders/image.zig` — reference implementation this RFC mirrors.
- `src/assets/loaders/font.zig` — current stub being replaced.
- `src/assets/loader.zig` — `DecodedPayload` / `UploadedResource` / `AssetLoaderVTable` shared types. `WorkRequest.params` extension lives here per §7.
- `src/assets/catalog.zig` — refcount + pump + failure path (largely unchanged; `registerFont` added).
- `src/gui_types.zig` — `Label.font_size: f32 = 16` today; `Label.font: ?[]const u8 = null` added in migration step 2.
- `src/game/gui_mixin.zig:52` — current label-render call site that gains the `?FontId` parameter.
- [stb_truetype](https://github.com/nothings/stb) — proposed decoder + atlas baker (public domain, single header).
- #444 (shipped) — `scene_assets_acquire` / `scene_assets_release` hooks and `asset_failure_policy`; font assets inherit this wiring unchanged.
- #447 — audio loader sibling RFC. Lands independently of this one.
