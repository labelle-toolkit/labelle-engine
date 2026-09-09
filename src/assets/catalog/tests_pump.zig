//! pump() tests (#442).
//!
//! These share a module-scoped mock backend for the image loader (see
//! `test_support.zig`) so each test can tune `decode_fails` /
//! `upload_fails` independently. `testing.allocator` is a GPA under the
//! hood, so a leaked CPU buffer or a double-free on any path below will
//! fail the test.

const std = @import("std");
const testing = std.testing;

const support = @import("test_support.zig");
const AssetCatalog = support.AssetCatalog;
const AssetState = support.AssetState;
const DecodedPayload = support.DecodedPayload;
const UploadedResource = support.UploadedResource;
const UPLOAD_BUDGET_PER_FRAME = support.UPLOAD_BUDGET_PER_FRAME;
const image_loader = support.image_loader;
const PumpMock = support.PumpMock;
const spinForResults = support.spinForResults;

const dummy_bytes = support.dummy_bytes;
const dummy_file_type = support.dummy_file_type;

test "pump: happy path transitions to .ready with resource populated" {
    PumpMock.reset();
    image_loader.setBackend(PumpMock.backend_value);
    defer image_loader.clearBackend();

    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.register("ship", .image, dummy_file_type, dummy_bytes);
    _ = try catalog.acquire("ship");

    try spinForResults(&catalog, 1);
    catalog.pump();

    const entry = catalog.entries.getPtr("ship").?;
    try testing.expectEqual(AssetState.ready, entry.state);
    try testing.expect(entry.resource != null);
    try testing.expect(entry.resource.?.image >= 500);
    try testing.expectEqual(@as(?DecodedPayload, null), entry.decoded);
    try testing.expectEqual(@as(?anyerror, null), entry.last_error);
    try testing.expectEqual(@as(u32, 1), PumpMock.upload_calls);
    // Catalog must report ready via the same query sites the scene
    // hooks (#444) will use.
    try testing.expect(catalog.isReady("ship"));
    // `release` on a `.ready` entry triggers `vtable.free` (#446),
    // which hands the texture back to the backend and clears
    // `entry.resource`. State rewinds to `.registered` so a later
    // `acquire` re-enqueues a fresh decode.
    catalog.release("ship");
    try testing.expectEqual(@as(u32, 1), PumpMock.unload_calls);
    try testing.expectEqual(@as(?UploadedResource, null), entry.resource);
    try testing.expectEqual(AssetState.registered, entry.state);
    try testing.expectEqual(@as(u32, 0), entry.refcount);
}

test "pump: zombie drop — release before upload rewinds to .registered and frees pixels" {
    PumpMock.reset();
    image_loader.setBackend(PumpMock.backend_value);
    defer image_loader.clearBackend();

    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.register("transient", .image, dummy_file_type, dummy_bytes);
    _ = try catalog.acquire("transient");

    // Wait for the worker to actually decode so there is an
    // allocator-owned pixel buffer pending on the result ring.
    try spinForResults(&catalog, 1);
    // Drop the refcount to zero *before* pump runs — this is the
    // classic "scene unloaded before its assets finished loading"
    // race the RFC §2 zombie-drop path protects against.
    catalog.release("transient");

    catalog.pump();

    const entry = catalog.entries.getPtr("transient").?;
    try testing.expectEqual(AssetState.registered, entry.state);
    try testing.expectEqual(@as(?DecodedPayload, null), entry.decoded);
    try testing.expectEqual(@as(?UploadedResource, null), entry.resource);
    // Upload must NOT have fired — the zombie path skips it entirely.
    try testing.expectEqual(@as(u32, 0), PumpMock.upload_calls);
    try testing.expectEqual(@as(u32, 0), PumpMock.unload_calls);
    // `testing.allocator` would report a leak here if the pixel buffer
    // from `decodeFn` was not handed back to `vtable.drop`.
}

test "pump: upload error bubbles to .failed and frees the CPU payload" {
    PumpMock.reset();
    image_loader.setBackend(PumpMock.backend_value);
    PumpMock.upload_fails = true;
    defer image_loader.clearBackend();

    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.register("bad-upload", .image, dummy_file_type, dummy_bytes);
    _ = try catalog.acquire("bad-upload");

    try spinForResults(&catalog, 1);
    catalog.pump();

    const entry = catalog.entries.getPtr("bad-upload").?;
    try testing.expectEqual(AssetState.failed, entry.state);
    try testing.expectEqual(
        @as(?anyerror, error.PumpMockUploadError),
        entry.last_error,
    );
    // Refcount is untouched — caller still owns the reference and
    // must `release` explicitly (per #442 state-transition contract).
    try testing.expectEqual(@as(u32, 1), entry.refcount);
    try testing.expectEqual(@as(?UploadedResource, null), entry.resource);
    // CPU payload was freed by pump's drop-on-upload-failure branch.
    try testing.expectEqual(@as(?DecodedPayload, null), entry.decoded);
    try testing.expectEqual(@as(u32, 1), PumpMock.upload_calls);
}

test "pump: worker-side decode error bubbles to .failed without touching upload" {
    PumpMock.reset();
    image_loader.setBackend(PumpMock.backend_value);
    PumpMock.decode_fails = true;
    defer image_loader.clearBackend();

    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.register("bad-decode", .image, dummy_file_type, dummy_bytes);
    _ = try catalog.acquire("bad-decode");

    try spinForResults(&catalog, 1);
    catalog.pump();

    const entry = catalog.entries.getPtr("bad-decode").?;
    try testing.expectEqual(AssetState.failed, entry.state);
    try testing.expectEqual(
        @as(?anyerror, error.PumpMockDecodeError),
        entry.last_error,
    );
    try testing.expectEqual(@as(u32, 0), PumpMock.upload_calls);
    try testing.expectEqual(@as(?UploadedResource, null), entry.resource);
    try testing.expectEqual(@as(?DecodedPayload, null), entry.decoded);
}

test "pump: UPLOAD_BUDGET_PER_FRAME caps finalised uploads per call" {
    PumpMock.reset();
    image_loader.setBackend(PumpMock.backend_value);
    defer image_loader.clearBackend();

    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    // Enqueue double the budget + a bit more to prove multiple pumps
    // finish the drain without losing any results.
    const total: u8 = UPLOAD_BUDGET_PER_FRAME * 2 + 1;
    var name_buffers: [total][16]u8 = undefined;
    var names: [total][]const u8 = undefined;
    for (0..total) |i| {
        names[i] = std.fmt.bufPrint(&name_buffers[i], "asset_{d}", .{i}) catch unreachable;
        try catalog.register(names[i], .image, dummy_file_type, dummy_bytes);
        _ = try catalog.acquire(names[i]);
    }

    try spinForResults(&catalog, total);

    // First pump drains exactly UPLOAD_BUDGET_PER_FRAME.
    catalog.pump();
    var ready_after_first: u32 = 0;
    for (names) |n| {
        if (catalog.isReady(n)) ready_after_first += 1;
    }
    try testing.expectEqual(@as(u32, UPLOAD_BUDGET_PER_FRAME), ready_after_first);

    // Second pump picks up another budget worth.
    catalog.pump();
    var ready_after_second: u32 = 0;
    for (names) |n| {
        if (catalog.isReady(n)) ready_after_second += 1;
    }
    try testing.expectEqual(@as(u32, UPLOAD_BUDGET_PER_FRAME * 2), ready_after_second);

    // Third pump drains the remainder (1 leftover).
    catalog.pump();
    var ready_final: u32 = 0;
    for (names) |n| {
        if (catalog.isReady(n)) ready_final += 1;
    }
    try testing.expectEqual(@as(u32, total), ready_final);

    // Release every entry through the catalog so the mock's unload
    // counter balances the upload counter — `release` on a `.ready`
    // entry now fires `vtable.free` per #446.
    for (names) |n| {
        catalog.release(n);
    }
    try testing.expectEqual(@as(u32, total), PumpMock.unload_calls);
}

test "pump: empty result ring is a no-op even with an active worker" {
    PumpMock.reset();
    image_loader.setBackend(PumpMock.backend_value);
    defer image_loader.clearBackend();

    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    // Register + acquire to spawn the worker, then immediately release
    // + pump before anything has been decoded. The worker may have
    // raced and produced a result; that is fine — the zombie path
    // handles it. The core assertion is "no panic, no leak".
    try catalog.register("ghost", .image, dummy_file_type, dummy_bytes);
    _ = try catalog.acquire("ghost");
    catalog.release("ghost");
    catalog.pump();

    const entry = catalog.entries.getPtr("ghost").?;
    // Either the worker never got there (state stuck at .queued) or
    // pump drained the zombie (state == .registered). Both are legal.
    try testing.expect(entry.state == .queued or entry.state == .registered);
}
