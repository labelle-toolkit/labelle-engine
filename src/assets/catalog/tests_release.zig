//! release() tests (#446).
//!
//! Focused on the `.ready` refcount-to-zero path: `release` must call
//! `vtable.free` so backend handles (GPU textures today, audio devices /
//! font atlases later) are returned to the backend. Before #446 the
//! catalog only cleared CPU state and rewound to `.registered`, which
//! leaked the texture handle for the whole program lifetime.

const std = @import("std");
const testing = std.testing;

const support = @import("test_support.zig");
const AssetCatalog = support.AssetCatalog;
const AssetState = support.AssetState;
const DecodedPayload = support.DecodedPayload;
const UploadedResource = support.UploadedResource;
const image_loader = support.image_loader;
const PumpMock = support.PumpMock;
const spinForResults = support.spinForResults;

const dummy_bytes = support.dummy_bytes;
const dummy_file_type = support.dummy_file_type;

test "release on .ready entry with refcount 1 calls vtable.free and rewinds state" {
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

    // The single-owner release: refcount hits zero, `.ready` path
    // fires `vtable.free` which hands the texture back to the backend,
    // clears `entry.resource`, and rewinds state for a future acquire.
    catalog.release("ship");

    try testing.expectEqual(@as(u32, 0), entry.refcount);
    try testing.expectEqual(AssetState.registered, entry.state);
    try testing.expectEqual(@as(?UploadedResource, null), entry.resource);
    try testing.expectEqual(@as(?DecodedPayload, null), entry.decoded);
    try testing.expectEqual(@as(u32, 1), PumpMock.unload_calls);
    try testing.expect(!catalog.isReady("ship"));
}

test "release on .ready entry with refcount > 1 decrements without unload" {
    PumpMock.reset();
    image_loader.setBackend(PumpMock.backend_value);
    defer image_loader.clearBackend();

    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.register("shared", .image, dummy_file_type, dummy_bytes);
    _ = try catalog.acquire("shared");
    _ = try catalog.acquire("shared");

    try spinForResults(&catalog, 1);
    catalog.pump();

    const entry = catalog.entries.getPtr("shared").?;
    try testing.expectEqual(AssetState.ready, entry.state);
    try testing.expectEqual(@as(u32, 2), entry.refcount);

    // First release: two owners → one owner. No unload, state stays
    // `.ready`, resource is still live.
    catalog.release("shared");
    try testing.expectEqual(@as(u32, 1), entry.refcount);
    try testing.expectEqual(AssetState.ready, entry.state);
    try testing.expect(entry.resource != null);
    try testing.expectEqual(@as(u32, 0), PumpMock.unload_calls);

    // Second release drops to zero: backend unload fires exactly once.
    catalog.release("shared");
    try testing.expectEqual(@as(u32, 0), entry.refcount);
    try testing.expectEqual(AssetState.registered, entry.state);
    try testing.expectEqual(@as(?UploadedResource, null), entry.resource);
    try testing.expectEqual(@as(u32, 1), PumpMock.unload_calls);
}

test "acquire after release round-trips cleanly on a ready asset" {
    PumpMock.reset();
    image_loader.setBackend(PumpMock.backend_value);
    defer image_loader.clearBackend();

    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.register("ship", .image, dummy_file_type, dummy_bytes);

    // Round 1: acquire → decode → pump → ready → release.
    _ = try catalog.acquire("ship");
    try spinForResults(&catalog, 1);
    catalog.pump();
    try testing.expect(catalog.isReady("ship"));

    catalog.release("ship");
    try testing.expectEqual(@as(u32, 1), PumpMock.unload_calls);
    try testing.expect(!catalog.isReady("ship"));

    // Round 2: fresh acquire re-enqueues through the worker, pump
    // finalises, state is `.ready` again with a NEW texture handle.
    _ = try catalog.acquire("ship");
    try spinForResults(&catalog, 1);
    catalog.pump();

    const entry = catalog.entries.getPtr("ship").?;
    try testing.expectEqual(AssetState.ready, entry.state);
    try testing.expect(entry.resource != null);
    try testing.expectEqual(@as(u32, 2), PumpMock.decode_calls);
    try testing.expectEqual(@as(u32, 2), PumpMock.upload_calls);
    try testing.expectEqual(@as(u32, 1), PumpMock.unload_calls);

    // Final release balances the books for the catalog's deinit.
    catalog.release("ship");
    try testing.expectEqual(@as(u32, 2), PumpMock.unload_calls);
}

test "release on .failed entry decrements refcount without calling free" {
    PumpMock.reset();
    image_loader.setBackend(PumpMock.backend_value);
    PumpMock.upload_fails = true;
    defer image_loader.clearBackend();

    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.register("broken", .image, dummy_file_type, dummy_bytes);
    _ = try catalog.acquire("broken");

    try spinForResults(&catalog, 1);
    catalog.pump();

    const entry = catalog.entries.getPtr("broken").?;
    try testing.expectEqual(AssetState.failed, entry.state);
    try testing.expectEqual(@as(?UploadedResource, null), entry.resource);
    try testing.expectEqual(@as(u32, 1), entry.refcount);

    // `.failed` has no resource to free and pump already dropped the
    // CPU payload, so `release` never calls the vtable's `free`. On
    // refcount-to-zero we rewind to `.registered` (clearing
    // `last_error`) so a later `acquire` can retry a transient
    // failure cleanly — leaving the entry stuck at `.failed` forever
    // would permanently brick it for no benefit.
    catalog.release("broken");
    try testing.expectEqual(@as(u32, 0), entry.refcount);
    try testing.expectEqual(AssetState.registered, entry.state);
    try testing.expectEqual(@as(?anyerror, null), entry.last_error);
    try testing.expectEqual(@as(u32, 0), PumpMock.unload_calls);
}

test "release past zero on a released .ready entry is idempotent" {
    PumpMock.reset();
    image_loader.setBackend(PumpMock.backend_value);
    defer image_loader.clearBackend();

    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.register("once", .image, dummy_file_type, dummy_bytes);
    _ = try catalog.acquire("once");
    try spinForResults(&catalog, 1);
    catalog.pump();

    // First release frees. Second + third releases are no-ops — no
    // double unload, no double free, testing.allocator stays happy.
    catalog.release("once");
    catalog.release("once");
    catalog.release("once");

    try testing.expectEqual(@as(u32, 1), PumpMock.unload_calls);

    const entry = catalog.entries.getPtr("once").?;
    try testing.expectEqual(@as(u32, 0), entry.refcount);
    try testing.expectEqual(AssetState.registered, entry.state);
}

test "deinit frees leftover .ready entries so GPU handles do not leak" {
    PumpMock.reset();
    image_loader.setBackend(PumpMock.backend_value);
    defer image_loader.clearBackend();

    var catalog = AssetCatalog.init(testing.allocator);

    try catalog.register("leaky", .image, dummy_file_type, dummy_bytes);
    _ = try catalog.acquire("leaky");
    try spinForResults(&catalog, 1);
    catalog.pump();

    // Intentionally skip `release` — simulate a game teardown where
    // the scene forgot to balance acquires. `deinit` must still hand
    // the GPU handle back to the backend.
    catalog.deinit();

    try testing.expectEqual(@as(u32, 1), PumpMock.unload_calls);
}
