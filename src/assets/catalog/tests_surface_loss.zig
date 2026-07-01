//! GPU surface-loss regression tests (epic #386 Phase 4).
//!
//! Host-side (no device) coverage of the catalog's GPU-context-loss
//! mechanism: `invalidateGpuResources` (Android TERM_WINDOW) drops the
//! stale GPU handle WITHOUT firing the loader's `free`/`unload` vtable —
//! the dead context can't safely destroy a stale texture — and rewinds
//! the entry to `.registered` while preserving its refcount.
//! `reenqueueGpuResident` (INIT_WINDOW) re-fires the decode → upload
//! pipeline so the asset re-uploads into the fresh context.
//!
//! Shares the image `PumpMock` from `test_support.zig`; the audio test
//! installs a tiny local audio backend mock so an `.audio` entry can
//! reach `.ready` and prove it is NOT invalidated by the image-only
//! GPU-loss path.

const std = @import("std");
const testing = std.testing;

const support = @import("test_support.zig");
const AssetCatalog = support.AssetCatalog;
const AssetState = support.AssetState;
const UploadedResource = support.UploadedResource;
const image_loader = support.image_loader;
const PumpMock = support.PumpMock;
const spinForResults = support.spinForResults;

const dummy_bytes = support.dummy_bytes;
const dummy_file_type = support.dummy_file_type;

const audio_loader = @import("../loaders/audio.zig");

/// Spin `pump()` until `name` reaches `.ready` or a bounded cap elapses
/// (a failed/wedged decode must not hang the test). Mirrors the
/// busy-pump in `loadAtlasIfNeededImpl`.
fn pumpUntilReady(catalog: *AssetCatalog, name: []const u8) !void {
    var spins: usize = 0;
    while (spins < 4096) : (spins += 1) {
        if (catalog.isReady(name)) return;
        if (catalog.lastError(name)) |err| return err;
        catalog.pump();
        std.Thread.yield() catch {};
    }
    return error.PumpDidNotReachReady;
}

test "surface loss: invalidate drops GPU handle without free, preserving refcount; restore re-decodes" {
    PumpMock.reset();
    image_loader.setBackend(PumpMock.backend_value);
    defer image_loader.clearBackend();

    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    // Acquire → pump → .ready (refcount 1, one decode + one upload).
    try catalog.register("ship", .image, dummy_file_type, dummy_bytes);
    _ = try catalog.acquire("ship");
    try spinForResults(&catalog, 1);
    try pumpUntilReady(&catalog, "ship");

    const entry = catalog.entries.getPtr("ship").?;
    try testing.expectEqual(AssetState.ready, entry.state);
    try testing.expect(entry.resource != null);
    try testing.expectEqual(@as(u32, 1), entry.refcount);
    try testing.expectEqual(@as(u32, 1), PumpMock.decode_calls);
    try testing.expectEqual(@as(u32, 0), PumpMock.unload_calls);

    // ── TERM_WINDOW ──
    catalog.invalidateGpuResources();

    // Stale handle dropped DIRECTLY: resource null, state rewound to
    // .registered, refcount UNTOUCHED, and crucially the loader's
    // free/unload vtable did NOT fire (unload_calls stays 0) — firing
    // it would `destroyTexture` a handle the dead context already
    // invalidated.
    try testing.expectEqual(@as(?UploadedResource, null), entry.resource);
    try testing.expectEqual(AssetState.registered, entry.state);
    try testing.expectEqual(@as(u32, 1), entry.refcount);
    try testing.expectEqual(@as(u32, 0), PumpMock.unload_calls);
    try testing.expect(!catalog.gpu_alive);

    // ── INIT_WINDOW ──
    catalog.reenqueueGpuResident();
    try testing.expect(catalog.gpu_alive);

    // Re-fired decode lands and re-uploads into the fresh context.
    try spinForResults(&catalog, 1);
    try pumpUntilReady(&catalog, "ship");

    try testing.expectEqual(AssetState.ready, entry.state);
    try testing.expect(entry.resource != null);
    try testing.expectEqual(@as(u32, 1), entry.refcount);
    // The CPU bitmap was freed after the first upload, so restore had
    // to RE-DECODE: a second decode (and a second upload) fired.
    try testing.expectEqual(@as(u32, 2), PumpMock.decode_calls);
    try testing.expectEqual(@as(u32, 2), PumpMock.upload_calls);
    // Still no free/unload across the whole loss→restore cycle.
    try testing.expectEqual(@as(u32, 0), PumpMock.unload_calls);

    // Balance the refcount so deinit doesn't fire `free` on the live
    // entry mid-teardown counting against unrelated assertions.
    catalog.release("ship");
}

test "surface loss: gpu_alive gate parks an in-flight image upload during TERM" {
    PumpMock.reset();
    image_loader.setBackend(PumpMock.backend_value);
    defer image_loader.clearBackend();

    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.register("late", .image, dummy_file_type, dummy_bytes);
    _ = try catalog.acquire("late");
    // Decode has landed on the result ring but we have NOT pumped the
    // upload yet — this is the in-flight decode that arrives mid-TERM.
    try spinForResults(&catalog, 1);

    // TERM_WINDOW fires before pump uploads it.
    catalog.invalidateGpuResources();

    // pump must NOT upload into the dead context — the result stays
    // PARKED on the ring (peeked, not dequeued). The entry is still
    // `.queued` (acquire set it there; the parked upload never ran to
    // flip it `.ready`, and invalidate only rewinds `.ready` entries),
    // refcount preserved, and no upload fired.
    catalog.pump();
    const entry = catalog.entries.getPtr("late").?;
    try testing.expectEqual(AssetState.queued, entry.state);
    try testing.expectEqual(@as(u32, 1), entry.refcount);
    try testing.expectEqual(@as(u32, 0), PumpMock.upload_calls);

    // INIT_WINDOW: re-enqueue flips gpu_alive back on. The parked
    // result now drains (and the re-enqueue may add a second decode);
    // either way the entry reaches `.ready` with at least one upload.
    catalog.reenqueueGpuResident();
    try spinForResults(&catalog, 1);
    try pumpUntilReady(&catalog, "late");
    try testing.expectEqual(AssetState.ready, entry.state);
    try testing.expect(PumpMock.upload_calls >= 1);

    catalog.release("late");
}

// ── Audio backend mock (proves audio is NOT GPU-invalidated) ──

const AudioMock = struct {
    var decode_calls: u32 = 0;
    var unload_calls: u32 = 0;

    fn reset() void {
        decode_calls = 0;
        unload_calls = 0;
    }

    fn decodeFn(
        file_type: [:0]const u8,
        data: []const u8,
        allocator: std.mem.Allocator,
    ) anyerror!audio_loader.DecodedAudio {
        _ = file_type;
        _ = data;
        decode_calls += 1;
        const samples = try allocator.alloc(i16, 2);
        @memset(samples, 0);
        return .{ .samples = samples, .sample_rate = 44100, .channels = 1 };
    }

    fn uploadFn(decoded: audio_loader.DecodedAudio) anyerror!@import("audio_types").SoundId {
        _ = decoded;
        return .{ .index = 7, .generation = 1 };
    }

    fn unloadFn(sound: @import("audio_types").SoundId) void {
        _ = sound;
        unload_calls += 1;
    }

    const backend_value: audio_loader.AudioBackend = .{
        .decode = decodeFn,
        .upload = uploadFn,
        .unload = unloadFn,
    };
};

test "surface loss: an .audio entry is NOT invalidated by GPU context loss" {
    AudioMock.reset();
    audio_loader.setBackend(AudioMock.backend_value);
    defer audio_loader.clearBackend();

    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.register("music", .audio, dummy_file_type, dummy_bytes);
    _ = try catalog.acquire("music");
    try spinForResults(&catalog, 1);
    try pumpUntilReady(&catalog, "music");

    const entry = catalog.entries.getPtr("music").?;
    try testing.expectEqual(AssetState.ready, entry.state);
    try testing.expect(entry.resource != null);

    // TERM_WINDOW: audio is not GPU-resident, so the loss path must
    // leave it fully intact — resource kept, state still `.ready`,
    // refcount untouched, and certainly no `unload` fired.
    catalog.invalidateGpuResources();
    try testing.expectEqual(AssetState.ready, entry.state);
    try testing.expect(entry.resource != null);
    try testing.expectEqual(@as(u32, 1), entry.refcount);
    try testing.expectEqual(@as(u32, 0), AudioMock.unload_calls);
    // It was decoded exactly once — restore must not re-decode audio.
    catalog.reenqueueGpuResident();
    try testing.expectEqual(@as(u32, 1), AudioMock.decode_calls);

    catalog.release("music");
}
