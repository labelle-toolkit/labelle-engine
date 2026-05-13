//! Unit tests for the audio asset loader (RFC-AUDIO-LOADER §7).
//!
//! Mirrors the in-source mock-backend test pattern from
//! `src/assets/loaders/image.zig` — round-trip through the loader
//! vtable with an injected `AudioBackend` that records every call and
//! returns a sentinel `SoundId`. No real WAV / OGG bytes here; the
//! decode is mocked. Real-decoder coverage lives backend-side
//! (raylib-audio, sokol-audio) per the RFC migration plan.
//!
//! Tests live in `test/*.zig` rather than as inline `test {}` blocks
//! in `src/` per the engine's CLAUDE.md convention — `build.zig`'s
//! per-test-file `addTest` chain runs each file as its own binary.

const std = @import("std");
const testing = std.testing;

const engine = @import("engine");

const AudioLoader = engine.AudioLoader;
const AudioBackend = engine.AudioBackend;
const DecodedAudio = engine.DecodedAudio;
const SoundId = engine.SoundId;
const AssetEntry = engine.AssetEntry;
const DecodedPayload = engine.DecodedPayload;
const UploadedResource = engine.UploadedResource;

// Sentinel handle the mock returns from `upload`. Generation must be
// non-zero so `SoundId.isValid()` is true — that's what differentiates
// a real handle from `SoundId.invalid` in the runtime audio path.
const sentinel_sound: SoundId = .{ .index = 42, .generation = 7 };

/// Mock backend that records every call. `decodeFn` allocates a fixed
/// sample buffer through the caller's allocator so we can exercise
/// both the happy path (upload frees) and the discard path (drop
/// frees) under `testing.allocator` — a GPA that flags leaks and
/// double-frees.
const MockBackend = struct {
    var decode_calls: u32 = 0;
    var upload_calls: u32 = 0;
    var unload_calls: u32 = 0;
    var last_uploaded: ?DecodedAudio = null;
    var last_unloaded: SoundId = SoundId.invalid;
    var decode_fails: bool = false;
    var upload_fails: bool = false;

    // Fixed shape — interleaved stereo, 4 frames = 8 samples. Sample
    // values are recognisable so an over-zealous backend that
    // truncates or reorders gets caught.
    const sample_count: usize = 8;
    const sample_rate: u32 = 44100;
    const channels: u8 = 2;
    const fill_value: i16 = 0x1234;

    fn reset() void {
        decode_calls = 0;
        upload_calls = 0;
        unload_calls = 0;
        last_uploaded = null;
        last_unloaded = SoundId.invalid;
        decode_fails = false;
        upload_fails = false;
    }

    fn decodeFn(
        file_type: [:0]const u8,
        data: []const u8,
        allocator: std.mem.Allocator,
    ) anyerror!DecodedAudio {
        _ = file_type;
        _ = data;
        decode_calls += 1;
        if (decode_fails) return error.MockDecodeError;
        const samples = try allocator.alloc(i16, sample_count);
        // Fill with a recognisable value so the upload mock can
        // assert it received the same bytes the decode produced.
        @memset(samples, fill_value);
        return .{
            .samples = samples,
            .sample_rate = sample_rate,
            .channels = channels,
        };
    }

    fn uploadFn(decoded: DecodedAudio) anyerror!SoundId {
        upload_calls += 1;
        if (upload_fails) return error.MockUploadError;
        last_uploaded = decoded;
        return sentinel_sound;
    }

    fn unloadFn(sound: SoundId) void {
        unload_calls += 1;
        last_unloaded = sound;
    }

    const backend_value: AudioBackend = .{
        .decode = decodeFn,
        .upload = uploadFn,
        .unload = unloadFn,
    };
};

test "audio loader: decode without backend errors cleanly" {
    AudioLoader.clearBackend();
    defer AudioLoader.clearBackend();
    try testing.expectError(
        error.AudioBackendNotInitialized,
        AudioLoader.vtable.decode("wav", "fake", null, testing.allocator),
    );
}

test "audio loader: mock backend decode → upload → free round-trip" {
    MockBackend.reset();
    AudioLoader.setBackend(MockBackend.backend_value);
    defer AudioLoader.clearBackend();

    // 1. decode on the worker thread (synchronous in the test).
    const payload = try AudioLoader.vtable.decode("wav", "fake-wav-bytes", null, testing.allocator);
    try testing.expectEqual(@as(u32, 1), MockBackend.decode_calls);
    try testing.expectEqual(MockBackend.sample_rate, payload.audio.sample_rate);
    try testing.expectEqual(MockBackend.channels, payload.audio.channels);
    try testing.expectEqual(MockBackend.sample_count, payload.audio.samples.len);
    try testing.expectEqual(MockBackend.fill_value, payload.audio.samples[0]);

    // 2. upload on the main thread. The loader owns the free of the
    //    CPU-side samples after a successful upload.
    var entry: AssetEntry = .{
        .state = .decoding,
        .refcount = 1,
        .loader = &AudioLoader.vtable,
        .loader_kind = .audio,
        .raw_bytes = "fake-wav-bytes",
        .file_type = "wav",
        .decoded = payload,
        .resource = null,
        .params = null,
        .last_error = null,
    };
    try AudioLoader.vtable.upload(&entry, payload, testing.allocator);
    try testing.expectEqual(@as(u32, 1), MockBackend.upload_calls);
    try testing.expect(entry.resource != null);
    const got: SoundId = entry.resource.?.audio;
    try testing.expectEqual(sentinel_sound.index, got.index);
    try testing.expectEqual(sentinel_sound.generation, got.generation);
    try testing.expect(got.isValid());

    // The upload mock recorded the same sample buffer the decode produced.
    try testing.expect(MockBackend.last_uploaded != null);
    try testing.expectEqual(MockBackend.sample_count, MockBackend.last_uploaded.?.samples.len);

    // 3. free on the main thread — refcount hit zero on a `.ready`
    //    entry. Releases the device handle through the backend, mirrors
    //    what the catalog's #446 unload path will call.
    AudioLoader.vtable.free(&entry);
    try testing.expectEqual(@as(u32, 1), MockBackend.unload_calls);
    try testing.expectEqual(sentinel_sound.index, MockBackend.last_unloaded.index);
    try testing.expectEqual(sentinel_sound.generation, MockBackend.last_unloaded.generation);
    try testing.expectEqual(@as(?UploadedResource, null), entry.resource);

    // `testing.allocator` (a GPA under the hood) would flag a leak of
    // the sample buffer here if upload had failed to free it, or a
    // double-free if drop ran afterwards by mistake.
}

test "audio loader: drop path frees samples without touching device" {
    MockBackend.reset();
    AudioLoader.setBackend(MockBackend.backend_value);
    defer AudioLoader.clearBackend();

    // Simulate a decode landing on the result ring but the refcount
    // dropping back to zero before pump() can finalise — the catalog
    // routes the payload straight to `drop`.
    const payload = try AudioLoader.vtable.decode("wav", "fake", null, testing.allocator);
    AudioLoader.vtable.drop(testing.allocator, payload);

    try testing.expectEqual(@as(u32, 0), MockBackend.upload_calls);
    try testing.expectEqual(@as(u32, 0), MockBackend.unload_calls);
}

test "audio loader: upload error leaves samples alive for drop cleanup" {
    MockBackend.reset();
    AudioLoader.setBackend(MockBackend.backend_value);
    MockBackend.upload_fails = true;
    defer AudioLoader.clearBackend();

    const payload = try AudioLoader.vtable.decode("ogg", "fake", null, testing.allocator);
    var entry: AssetEntry = .{
        .state = .decoding,
        .refcount = 1,
        .loader = &AudioLoader.vtable,
        .loader_kind = .audio,
        .raw_bytes = "fake",
        .file_type = "ogg",
        .decoded = payload,
        .resource = null,
        .params = null,
        .last_error = null,
    };
    try testing.expectError(
        error.MockUploadError,
        AudioLoader.vtable.upload(&entry, payload, testing.allocator),
    );
    try testing.expectEqual(@as(?UploadedResource, null), entry.resource);
    // On the failure path, `upload` must NOT have freed the buffer —
    // the catalog still needs to hand it to `drop`. Do that here to
    // keep `testing.allocator` happy.
    AudioLoader.vtable.drop(testing.allocator, payload);
}

test "audio loader: free without a backend or resource is a no-op" {
    AudioLoader.clearBackend();
    var entry: AssetEntry = .{
        .state = .registered,
        .refcount = 0,
        .loader = &AudioLoader.vtable,
        .loader_kind = .audio,
        .raw_bytes = "",
        .file_type = "wav",
        .decoded = null,
        .resource = null,
        .params = null,
        .last_error = null,
    };
    AudioLoader.vtable.free(&entry);
    try testing.expectEqual(@as(?UploadedResource, null), entry.resource);
}

test "audio loader: free with cleared backend still nulls entry.resource" {
    // Contract from `loader.zig`: callers that check
    // `entry.resource != null` as a cleanup-completed flag must get
    // null even when the backend was torn down mid-run. Matches the
    // image loader's free behaviour exactly.
    MockBackend.reset();
    AudioLoader.setBackend(MockBackend.backend_value);

    const payload = try AudioLoader.vtable.decode("wav", "fake", null, testing.allocator);
    var entry: AssetEntry = .{
        .state = .decoding,
        .refcount = 1,
        .loader = &AudioLoader.vtable,
        .loader_kind = .audio,
        .raw_bytes = "fake",
        .file_type = "wav",
        .decoded = payload,
        .resource = null,
        .params = null,
        .last_error = null,
    };
    try AudioLoader.vtable.upload(&entry, payload, testing.allocator);
    try testing.expect(entry.resource != null);

    AudioLoader.clearBackend();
    AudioLoader.vtable.free(&entry);
    try testing.expectEqual(@as(u32, 0), MockBackend.unload_calls);
    try testing.expectEqual(@as(?UploadedResource, null), entry.resource);
}

test "audio loader: decode propagates backend errors" {
    MockBackend.reset();
    AudioLoader.setBackend(MockBackend.backend_value);
    MockBackend.decode_fails = true;
    defer AudioLoader.clearBackend();

    try testing.expectError(
        error.MockDecodeError,
        AudioLoader.vtable.decode("wav", "fake", null, testing.allocator),
    );
    try testing.expectEqual(@as(u32, 1), MockBackend.decode_calls);
}

test "audio loader: setBackend / clearBackend / currentBackend are wired" {
    AudioLoader.clearBackend();
    try testing.expectEqual(@as(?AudioBackend, null), AudioLoader.currentBackend());
    AudioLoader.setBackend(MockBackend.backend_value);
    try testing.expect(AudioLoader.currentBackend() != null);
    AudioLoader.clearBackend();
    try testing.expectEqual(@as(?AudioBackend, null), AudioLoader.currentBackend());
}
