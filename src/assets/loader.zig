//! Asset entry state, loader vtable + decoded payload / uploaded
//! resource unions.
//!
//! Owns the shared types that both the catalog and the concrete loaders
//! (image, audio, font) need. Keeping them here avoids a circular
//! dependency: `catalog.zig` imports this file; this file does not
//! import `catalog.zig`.
//!
//! Concrete loaders live in `loaders/` and provide a
//! `pub const vtable: AssetLoaderVTable` that the catalog stores on
//! each `AssetEntry` at registration time.
//!
//! ## Where does the uploaded GPU/device handle live?
//!
//! `AssetEntry.decoded` holds the worker-thread CPU-side payload
//! (RGBA pixels for images, sample buffers for audio, glyph rasters
//! for fonts). After `loader.upload` runs on the main thread, we also
//! need a slot for the post-upload "real thing" — a GPU texture
//! handle, an audio device id, a font atlas pointer, … — so `pump()`
//! (#442), `isReady`, and the eventual unload path (#446) can see it
//! without walking private loader state.
//!
//! Phase 1 picks **option 1** from the #440 ticket: extend `AssetEntry`
//! with a second `resource: ?UploadedResource` field, parallel to the
//! existing `decoded`. This keeps the CPU-side and GPU-side slots
//! independent, matches the RFC §2 sketch ("decoded: union { texture,
//! audio, font }"), and survives the #441 / #442 / #446 tickets cleanly.
//! The alternative — reusing `decoded` as a "before OR after" union —
//! was rejected because Zig unions are comptime-tagged so the variant
//! types have to be decided up front.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Discriminator for `DecodedPayload` and for selecting a loader at
/// `AssetCatalog.register` time. Stored on the entry; callers do not
/// need to namespace asset names per loader.
pub const LoaderKind = enum { image, audio, font };

/// Opaque GPU texture handle used by the image loader. Matches the
/// `u32` texture id convention in `src/atlas.zig` so existing atlas
/// consumers can read it out of `entry.resource.?.image` without a
/// conversion layer when the legacy shim lands in #443.
pub const Texture = u32;

/// Worker-thread output. Variants are populated on the worker, then
/// either uploaded (success path) or dropped (refcount-zero discard
/// path) on the main thread. Real payload shapes for `audio` and
/// `font` arrive in Phase 4 — they are placeholders for now.
pub const DecodedPayload = union(LoaderKind) {
    image: struct {
        pixels: []u8, // RGBA8, allocator-owned
        width: u32,
        height: u32,
    },
    audio: struct {}, // placeholder for Phase 4 (#441)
    font: struct {}, // placeholder for Phase 4 (#441)
};

/// Main-thread "after upload" payload. Populated by `loader.upload`
/// once the CPU-side `DecodedPayload` has been handed to the backend
/// (GPU for images, audio device for sounds, atlas for fonts). Cleared
/// by `loader.free` on the unload path (#446). The `audio` and `font`
/// variants are placeholders until #441.
pub const UploadedResource = union(LoaderKind) {
    image: Texture,
    audio: struct {}, // placeholder for Phase 4 (#441)
    font: struct {}, // placeholder for Phase 4 (#441)
};

/// Lifecycle of a single entry.
///
/// `registered` — metadata is in the catalog, no decode in flight.
/// `queued`     — refcount > 0, work request enqueued for the worker.
/// `decoding`   — worker has picked up the request.
/// `ready`      — `decoded` is populated and `upload` succeeded.
/// `failed`     — `last_error` is set; `pump()` will not retry.
pub const AssetState = enum { registered, queued, decoding, ready, failed };

pub const AssetEntry = struct {
    state: AssetState,
    refcount: u32,
    loader: *const AssetLoaderVTable,
    loader_kind: LoaderKind,
    /// Borrowed from `@embedFile` — program lifetime, never freed.
    raw_bytes: []const u8,
    /// Borrowed sentinel-terminated string — program lifetime.
    file_type: [:0]const u8,
    /// Populated by the worker's decode path and consumed by
    /// `loader.upload`. Cleared back to `null` by `pump()` (#442) once
    /// the upload has moved ownership into `resource`, or by
    /// `loader.drop` on the refcount-zero discard path.
    decoded: ?DecodedPayload,
    /// Populated by `loader.upload` on the success path — holds the
    /// backend-side handle (GPU texture, audio device id, font atlas,
    /// …) that `isReady` and the eventual unload path in #446 read.
    /// Cleared by `loader.free` when refcount returns to zero on a
    /// `.ready` entry.
    resource: ?UploadedResource,
    last_error: ?anyerror,
};

/// Per-asset-type plug-in. Every loader (image, audio, font, …)
/// provides one of these. The catalog calls `decode` on the worker
/// thread and `upload` / `drop` / `free` on the main thread — see
/// the threading invariant in `catalog.zig`.
pub const AssetLoaderVTable = struct {
    /// Worker-thread CPU decode. Allocator-owned output stored on the
    /// resulting `WorkResult.decoded`. May return error → result.err
    /// is set and the entry transitions to `.failed` in `pump()`.
    decode: *const fn (
        file_type: [:0]const u8,
        data: []const u8,
        allocator: Allocator,
    ) anyerror!DecodedPayload,

    /// Main-thread finalise: GPU upload, audio device handle, font
    /// glyph rasterise — whatever turns the worker output into the
    /// `.ready` representation. On success the loader stashes the
    /// resulting handle on `entry.resource` AND frees the CPU-side
    /// `decoded` payload via `allocator` — the labelle-gfx contract
    /// says `uploadTexture` does NOT take ownership of the pixels.
    /// On failure the loader leaves the CPU payload alive and
    /// returns the error; `pump()` (#442) routes the entry to
    /// `.failed`, and the CPU payload is freed via `drop` as part of
    /// teardown.
    upload: *const fn (
        entry: *AssetEntry,
        decoded: DecodedPayload,
        allocator: Allocator,
    ) anyerror!void,

    /// Discard path: refcount hit zero between decode and upload.
    /// Frees the CPU-side payload without touching the GPU.
    drop: *const fn (allocator: Allocator, decoded: DecodedPayload) void,

    /// Unload path: refcount hit zero on a `.ready` asset. Releases
    /// the GPU/audio/font resource that `upload` created and clears
    /// `entry.resource` back to `null`. Wired up in ticket #446.
    free: *const fn (entry: *AssetEntry) void,
};
