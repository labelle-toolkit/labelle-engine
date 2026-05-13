const std = @import("std");

/// CPU-decoded audio owned by the caller's allocator.
///
/// Mirrors the audio-loader split that `labelle-gfx`'s `DecodedImage` and
/// `DecodedFont` introduced for the Asset Streaming RFC: pure CPU decode
/// happens on a worker thread; "upload" (audio-device-side registration)
/// happens on the main thread. The sample buffer is allocator-owned so the
/// asset catalog can free it on BOTH the success path and the discard path
/// (when a refcount hits zero between decode and upload).
///
/// Structurally identical to `labelle-engine`'s
/// `DecodedPayload.audio` inline struct so the assembler adapter is a 1:1
/// field copy — same trick used for `DecodedImage` and `DecodedFont`.
pub const DecodedAudio = struct {
    /// Interleaved PCM samples (channels interleaved per frame). Length is
    /// `frame_count * channels`. Owned by the allocator passed to
    /// `decodeAudio`; the caller frees via that same allocator on both the
    /// success and discard paths.
    samples: []i16,
    sample_rate: u32,
    channels: u8,
};

/// Creates a validated backend interface from an implementation type.
///
/// The wrapper enforces the audio-loader contract — concrete decoder
/// backends (raylib-audio, sokol-audio, miniaudio, …) implement `Impl`;
/// the assembler adapts the resulting wrapper to `labelle-engine`'s
/// `AudioBackend` struct of function pointers at codegen time. Same shape
/// as `labelle-gfx`'s `Backend(Impl)` for images and fonts.
///
/// Runtime audio playback (`AudioInterface`-style) lives in `labelle-core`
/// and stays there — this repo is decoder/loader-side only.
pub fn Backend(comptime Impl: type) type {
    comptime {
        if (!@hasDecl(Impl, "Sound")) @compileError("Backend must define 'Sound' type");
    }

    comptime {
        if (!@hasDecl(Impl, "decodeAudio")) @compileError("Backend must define 'decodeAudio' (worker-thread safe CPU decode)");
        if (!@hasDecl(Impl, "uploadSound")) @compileError("Backend must define 'uploadSound' (main-thread audio-device registration)");
        if (!@hasDecl(Impl, "unloadSound")) @compileError("Backend must define 'unloadSound'");
    }

    return struct {
        pub const Implementation = Impl;

        /// Opaque backend-side sound handle. Resolves to the backend's
        /// own type — the adapter on the assembler side narrows this to
        /// `labelle-engine`'s `SoundId` shape (same marshalling trick
        /// `labelle-gfx` uses for `Texture` vs the engine's `Texture`
        /// POD).
        pub const Sound = Impl.Sound;

        /// Pure CPU decode, safe to call from a worker thread. Returns a
        /// `DecodedAudio` whose `samples` buffer is owned by `allocator` —
        /// the caller frees it via that same allocator on BOTH the success
        /// and the discard paths (see `uploadSound`).
        pub inline fn decodeAudio(
            file_type: [:0]const u8,
            data: []const u8,
            allocator: std.mem.Allocator,
        ) !DecodedAudio {
            return Impl.decodeAudio(file_type, data, allocator);
        }

        /// Main-thread audio-device registration. Hands the decoded
        /// samples to the backend's mixer / audio device and returns a
        /// backend `Sound` handle. Does NOT take ownership of
        /// `decoded.samples` — the caller is responsible for freeing the
        /// buffer on both the success path and the discard path (e.g.
        /// when the asset catalog drops the asset between decode and
        /// upload).
        pub inline fn uploadSound(decoded: DecodedAudio) !Sound {
            return Impl.uploadSound(decoded);
        }

        /// Releases the audio-device-side resource that `uploadSound`
        /// allocated. Counterpart to `uploadSound`.
        pub inline fn unloadSound(sound: Sound) void {
            Impl.unloadSound(sound);
        }
    };
}
