//! Main-thread decode tests (#877).
//!
//! On single-threaded targets (WASM) no worker thread can run, so the
//! catalog decodes on the main thread. Before #877 it did so inside
//! `acquire`, and a scene swap to several assets froze the page for all of
//! them in one frame. Now `acquire` only queues, and `pump()` decodes
//! `MAIN_THREAD_DECODES_PER_PUMP` per call. These tests drive that path on
//! a native (threaded) build by setting `main_thread_decode` before the
//! first `acquire`, and assert the DECODE COUNT per pump, not just the end
//! state, since "everything ended up ready" was also true of the freezing
//! version.

const std = @import("std");
const testing = std.testing;

const support = @import("test_support.zig");
const AssetCatalog = support.AssetCatalog;
const AssetState = support.AssetState;
const image_loader = support.image_loader;
const PumpMock = support.PumpMock;
const engine = @import("engine.zig");

const dummy_bytes = support.dummy_bytes;
const dummy_file_type = support.dummy_file_type;

fn mainThreadCatalog() AssetCatalog {
    var catalog = AssetCatalog.init(testing.allocator);
    catalog.main_thread_decode = true;
    return catalog;
}

test "main-thread decode: acquire only queues, it never decodes" {
    PumpMock.reset();
    image_loader.setBackend(PumpMock.backend_value);
    defer image_loader.clearBackend();

    var catalog = mainThreadCatalog();
    defer catalog.deinit();

    try catalog.register("ship", .image, dummy_file_type, dummy_bytes);
    const entry = try catalog.acquire("ship");

    // The #877 freeze was this call decoding synchronously.
    try testing.expectEqual(AssetState.queued, entry.state);
    try testing.expectEqual(@as(u32, 0), PumpMock.decode_calls);
    // And no thread was spawned to decode it behind our back.
    for (catalog.workers) |w| try testing.expect(w.thread == null);
}

test "main-thread decode: one decode per pump, so assets land on separate frames" {
    PumpMock.reset();
    image_loader.setBackend(PumpMock.backend_value);
    defer image_loader.clearBackend();

    var catalog = mainThreadCatalog();
    defer catalog.deinit();

    // A scene swap acquiring three atlases in one frame.
    const names = [_][]const u8{ "ship", "rooms", "characters" };
    for (names) |n| try catalog.register(n, .image, dummy_file_type, dummy_bytes);
    for (names) |n| _ = try catalog.acquire(n);
    try testing.expectEqual(@as(u32, 0), PumpMock.decode_calls);

    // Each pump decodes exactly one and uploads it the same frame.
    var ready: u32 = 0;
    for (0..names.len) |frame| {
        catalog.pump();
        try testing.expectEqual(@as(u32, @intCast(frame + 1)), PumpMock.decode_calls);
        ready = 0;
        for (names) |n| {
            if (catalog.isReady(n)) ready += 1;
        }
        try testing.expectEqual(@as(u32, @intCast(frame + 1)), ready);
    }
    try testing.expect(catalog.allReady(&names));

    // Nothing left: further pumps decode nothing more.
    catalog.pump();
    try testing.expectEqual(@as(u32, names.len), PumpMock.decode_calls);

    for (names) |n| catalog.release(n);
}

test "main-thread decode: a decode failure still lands as .failed through pump" {
    PumpMock.reset();
    PumpMock.decode_fails = true;
    image_loader.setBackend(PumpMock.backend_value);
    defer image_loader.clearBackend();

    var catalog = mainThreadCatalog();
    defer catalog.deinit();

    try catalog.register("broken", .image, dummy_file_type, dummy_bytes);
    const entry = try catalog.acquire("broken");
    try testing.expectEqual(AssetState.queued, entry.state);

    catalog.pump();
    try testing.expectEqual(AssetState.failed, entry.state);
    try testing.expect(entry.last_error != null);
    catalog.release("broken");
}

test "main-thread decode is the single-threaded default, and only there" {
    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();
    try testing.expectEqual(@import("builtin").single_threaded, catalog.main_thread_decode);
    try testing.expectEqual(@as(u8, 1), engine.MAIN_THREAD_DECODES_PER_PUMP);
}
