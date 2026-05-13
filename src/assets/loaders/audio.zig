//! Audio loader — CPU-decode on the worker, audio-device upload on the
//! main thread, backed by a runtime-injected `AudioBackend`.
//!
//! Structural twin of `loaders/image.zig`. Read that file's preamble
//! for the full rationale on why this module exposes a runtime hook
//! struct instead of importing an audio backend directly — the same
//! dependency-boundary argument applies here. The engine crate does
//! not depend on raylib-audio, sokol-audio, or any other concrete
//! audio backend; the assembler injects adapters at `Game.init` time
//! via `setBackend`.
//!
//! ## Threading
//!
//! * `decode` runs on the asset worker thread. It calls
//!   `backend.decode(file_type, data, allocator)` — single-header
//!   decoders (`dr_wav`, `stb_vorbis`) on the backend side are pure
//!   CPU, no device calls, so that is safe.
//! * `upload`, `drop`, `free` all run on the main thread from
//!   `AssetCatalog.pump()` / `AssetCatalog.deinit()` / the unload path.
//!   `upload` and `free` call back into the backend on the main thread
//!   for audio-device operations.
//!
//! ## Ownership of `DecodedAudio.samples`
//!
//! * `decode` allocates the sample buffer through the provided
//!   allocator — same allocator the worker hands in, same allocator
//!   that later frees the buffer.
//! * `upload` calls `backend.upload` (which **copies** the samples to
//!   the audio device) and then frees the CPU buffer via `allocator`.
//!   The backend contract says `upload` does NOT take ownership.
//! * `drop` is the refcount-zero-during-decode path: free the CPU
//!   buffer, leave the device alone.
//! * `free` is the refcount-zero-on-ready path: release the
//!   `SoundId` through `backend.unload`; the CPU buffer is already gone.
//!
//! ## Why `audio_types.SoundId` instead of a loader-local handle?
//!
//! The engine already has `audio_types.SoundId` — a `{ index, generation }`
//! struct with `isValid` + generation-based staleness detection, used
//! across the runtime audio interface in `src/audio.zig`. Minting a
//! second handle type here would split the sound-handle vocabulary in
//! two. The backend builds a `SoundId` from whatever raw integer the
//! native audio device hands back; the catalog and the rest of the
//! engine only ever see the shared struct.

const std = @import("std");
const Allocator = std.mem.Allocator;

const audio_types = @import("audio_types");

const loader = @import("../loader.zig");

const AssetLoaderVTable = loader.AssetLoaderVTable;
const DecodedPayload = loader.DecodedPayload;
const UploadedResource = loader.UploadedResource;
const AssetEntry = loader.AssetEntry;

/// CPU-side decoded interleaved 16-bit PCM, allocator-owned. Kept
/// intentionally plain so the backend adapter can bridge it to
/// whatever `DecodedAudio` shape the native single-header decoders
/// produce on its side of the dependency boundary without a
/// nominal-type conflict. See RFC §2 for sample-format rationale.
pub const DecodedAudio = struct {
    samples: []i16, // interleaved signed 16-bit PCM, allocator-owned
    sample_rate: u32, // 22050, 44100, 48000, …
    channels: u8, // 1 = mono, 2 = stereo
};

/// Runtime backend hook. The assembler fills this in at `Game.init`
/// by calling `setBackend` with adapters that forward to e.g.
/// raylib-audio's `LoadSoundFromWave` / `UnloadSound` (via the
/// backend's `dr_wav` / `stb_vorbis` decoders). Tests inject a mock
/// the same way — see `test/audio_loader_test.zig`.
pub const AudioBackend = struct {
    /// Worker-thread CPU decode. Returns a `DecodedAudio` whose
    /// `samples` slice is owned by `allocator`. Errors bubble to
    /// `WorkResult.err`.
    decode: *const fn (
        file_type: [:0]const u8,
        data: []const u8,
        allocator: Allocator,
    ) anyerror!DecodedAudio,

    /// Main-thread audio-device upload. Copies samples to a new
    /// device-side buffer and returns the `SoundId`. Does NOT take
    /// ownership of `decoded.samples` — the caller frees.
    upload: *const fn (decoded: DecodedAudio) anyerror!audio_types.SoundId,

    /// Main-thread audio-device release. The counterpart to `upload`.
    unload: *const fn (sound: audio_types.SoundId) void,
};

/// Private module-level slot for the injected backend. `null` until
/// the assembler calls `setBackend` — backends that have not wired the
/// hook yet surface as `error.AudioBackendNotInitialized` rather than a
/// null deref. Identical pattern to `loaders/image.zig`.
var active_backend: ?AudioBackend = null;

/// Install the runtime backend. Call exactly once during game init,
/// before any audio asset is acquired. Idempotent for tests: the
/// second call just overwrites the slot.
pub fn setBackend(b: AudioBackend) void {
    active_backend = b;
}

/// Clear the backend slot. Used by tests to return to a clean state
/// between runs so one test's mock does not leak into the next.
pub fn clearBackend() void {
    active_backend = null;
}

/// Read-side accessor for tests / diagnostics.
pub fn currentBackend() ?AudioBackend {
    return active_backend;
}

fn decode(
    file_type: [:0]const u8,
    data: []const u8,
    params: ?*const anyopaque,
    allocator: Allocator,
) anyerror!DecodedPayload {
    _ = params; // audio loader doesn't take decode params
    const b = active_backend orelse return error.AudioBackendNotInitialized;
    const decoded = try b.decode(file_type, data, allocator);
    return .{ .audio = .{
        .samples = decoded.samples,
        .sample_rate = decoded.sample_rate,
        .channels = decoded.channels,
    } };
}

fn upload(
    entry: *AssetEntry,
    decoded_payload: DecodedPayload,
    allocator: Allocator,
) anyerror!void {
    const b = active_backend orelse return error.AudioBackendNotInitialized;
    const audio = switch (decoded_payload) {
        .audio => |a| a,
        else => return error.WrongDecodedPayloadKind,
    };

    // Hand the samples to the audio device first — if this errors we
    // still want the CPU buffer freed by `drop` on the teardown path,
    // so leave it alive here and let the error propagate.
    const sound = try b.upload(.{
        .samples = audio.samples,
        .sample_rate = audio.sample_rate,
        .channels = audio.channels,
    });

    // Upload succeeded: the device has its own copy, so we can release
    // the allocator-owned CPU buffer now. The backend contract says
    // `upload` does NOT take ownership of `samples`.
    allocator.free(audio.samples);

    entry.resource = .{ .audio = sound };
}

fn drop(allocator: Allocator, decoded_payload: DecodedPayload) void {
    switch (decoded_payload) {
        .audio => |a| allocator.free(a.samples),
        // Other variants never reach the audio loader's drop hook —
        // the catalog dispatches on the vtable carried by the
        // `WorkResult`, not on `DecodedPayload`'s tag. Keep the arms
        // exhaustive so this file compiles cleanly against future
        // payload shapes.
        else => {},
    }
}

fn free(entry: *AssetEntry) void {
    const resource = entry.resource orelse return;
    // Release the device-side handle if a backend is installed. If
    // the backend was cleared (e.g. a test's `clearBackend`) after an
    // asset uploaded, we can't reach the device — skip the `unload`
    // call but STILL clear `entry.resource` so callers that check
    // `entry.resource != null` as a cleanup-completed flag get the
    // contract `loader.zig` documents. Mirrors `image.zig::free`.
    if (active_backend) |b| switch (resource) {
        .audio => |sound| b.unload(sound),
        else => {},
    };
    entry.resource = null;
}

pub const vtable: AssetLoaderVTable = .{
    .decode = decode,
    .upload = upload,
    .drop = drop,
    .free = free,
};
