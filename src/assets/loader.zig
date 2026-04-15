//! Asset loader vtable + decoded payload union.
//!
//! Concrete loaders (image, audio, font) live in `loaders/` and provide
//! a `pub const vtable: AssetLoaderVTable` that the catalog stores on
//! each `AssetEntry` at registration time.
//!
//! This file declares **types only** — no implementations. The real
//! image loader lands in ticket #440, audio/font in #441.

const std = @import("std");
const Allocator = std.mem.Allocator;

const catalog = @import("catalog.zig");
const AssetEntry = catalog.AssetEntry;

/// Discriminator for `DecodedPayload` and for selecting a loader at
/// `AssetCatalog.register` time. Stored on the entry; callers do not
/// need to namespace asset names per loader.
pub const LoaderKind = enum { image, audio, font };

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
    /// `.ready` representation. Frees the CPU-side payload on the
    /// success path.
    upload: *const fn (entry: *AssetEntry, decoded: DecodedPayload) anyerror!void,

    /// Discard path: refcount hit zero between decode and upload.
    /// Frees the CPU-side payload without touching the GPU.
    drop: *const fn (allocator: Allocator, decoded: DecodedPayload) void,

    /// Unload path: refcount hit zero on a `.ready` asset. Releases
    /// the GPU/audio/font resource that `upload` created. Wired up
    /// in ticket #446.
    free: *const fn (entry: *AssetEntry) void,
};
