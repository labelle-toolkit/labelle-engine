//! Lifecycle tests: register / acquire / release / readiness queries,
//! plus the early worker-spawn and deinit smoke tests. The pump-state
//! and #446 release tests live in their sibling test files.

const std = @import("std");
const testing = std.testing;

const support = @import("test_support.zig");
const AssetCatalog = support.AssetCatalog;
const AssetState = support.AssetState;
const LoaderKind = support.LoaderKind;
const DecodedPayload = support.DecodedPayload;
const image_loader = support.image_loader;
const sleepNs = support.sleepNs;

const dummy_bytes = support.dummy_bytes;
const dummy_file_type = support.dummy_file_type;

test "register then acquire bumps refcount and enqueues work" {
    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.register("background", .image, dummy_file_type, dummy_bytes);

    const entry = try catalog.acquire("background");
    try testing.expectEqual(@as(u32, 1), entry.refcount);
    // First acquire moved the entry to `.queued` — the worker ring
    // has taken ownership of the request and will eventually publish
    // an `error.ImageBackendNotInitialized` result on the real image
    // loader (no backend injected in the unit-test harness).
    try testing.expectEqual(AssetState.queued, entry.state);
    try testing.expectEqual(LoaderKind.image, entry.loader_kind);
    try testing.expectEqual(@as(?DecodedPayload, null), entry.decoded);
}

test "double acquire then release ordering" {
    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.register("ship", .image, dummy_file_type, dummy_bytes);

    const e1 = try catalog.acquire("ship");
    _ = try catalog.acquire("ship");
    try testing.expectEqual(@as(u32, 2), e1.refcount);

    catalog.release("ship");
    try testing.expectEqual(@as(u32, 1), e1.refcount);

    catalog.release("ship");
    try testing.expectEqual(@as(u32, 0), e1.refcount);
    // State stays at `.queued` until `pump()` (#442) drains the
    // worker result — `release` on a non-`.ready` entry only touches
    // the refcount.
    try testing.expectEqual(AssetState.queued, e1.state);
}

test "release on already-zero entry is a no-op" {
    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.register("ship", .image, dummy_file_type, dummy_bytes);
    catalog.release("ship");
    catalog.release("ship");
    catalog.release("unknown-asset");

    const entry = catalog.entries.getPtr("ship").?;
    try testing.expectEqual(@as(u32, 0), entry.refcount);
}

test "isReady is false for a fresh registration" {
    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.register("background", .image, dummy_file_type, dummy_bytes);
    try testing.expect(!catalog.isReady("background"));
    try testing.expect(!catalog.isReady("never-registered"));
}

test "allReady returns true for an empty slice" {
    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    const names: []const []const u8 = &.{};
    try testing.expect(catalog.allReady(names));
    try testing.expectEqual(@as(f32, 1.0), catalog.progress(names));
}

test "progress reflects mixed ready states" {
    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.register("a", .image, dummy_file_type, dummy_bytes);
    try catalog.register("b", .image, dummy_file_type, dummy_bytes);

    const names: []const []const u8 = &.{ "a", "b" };
    try testing.expectEqual(@as(f32, 0.0), catalog.progress(names));
    try testing.expect(!catalog.allReady(names));

    // Simulate the worker / pump path by forcing one entry to ready.
    // The real transition lands with #442; for the unit test we just
    // need a `.ready` entry to verify the bookkeeping.
    const a = try catalog.acquire("a");
    a.state = .ready;
    try testing.expectEqual(@as(f32, 0.5), catalog.progress(names));
    try testing.expect(!catalog.allReady(names));

    const b = try catalog.acquire("b");
    b.state = .ready;
    try testing.expectEqual(@as(f32, 1.0), catalog.progress(names));
    try testing.expect(catalog.allReady(names));
}

test "lastError is null for a never-failed entry" {
    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.register("background", .image, dummy_file_type, dummy_bytes);
    try testing.expectEqual(@as(?anyerror, null), catalog.lastError("background"));
    try testing.expectEqual(@as(?anyerror, null), catalog.lastError("unknown"));
}

test "duplicate register returns AssetAlreadyRegistered" {
    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.register("ship", .image, dummy_file_type, dummy_bytes);
    try testing.expectError(
        error.AssetAlreadyRegistered,
        catalog.register("ship", .image, dummy_file_type, dummy_bytes),
    );
}

test "acquire on unknown asset returns AssetNotRegistered" {
    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try testing.expectError(error.AssetNotRegistered, catalog.acquire("ghost"));
}

test "pump on an empty result ring is a no-op" {
    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.register("background", .image, dummy_file_type, dummy_bytes);
    // No acquire → worker never spawned, no results to drain. `pump`
    // must stay passive — no panic, no state change, no allocation.
    catalog.pump();
    const entry = catalog.entries.getPtr("background").?;
    try testing.expectEqual(AssetState.registered, entry.state);
    try testing.expect(!catalog.isReady("background"));
}

test "acquire spawns worker which surfaces ImageBackendNotInitialized without a backend" {
    // Make sure no previous test left a backend injected on this
    // process-global slot — the assertions below rely on the loader
    // returning the not-initialised error, not a mock success.
    image_loader.clearBackend();

    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.register("background", .image, dummy_file_type, dummy_bytes);
    _ = try catalog.acquire("background");

    // Spin up to 200ms waiting for the worker to publish a result.
    // `pump()` is still a no-op (#442) so we peek at the ring
    // directly to verify the machinery.
    const deadline_ns: u64 = 200 * std.time.ns_per_ms;
    var waited_ns: u64 = 0;
    const step_ns: u64 = 1 * std.time.ns_per_ms;
    const result = outer: while (waited_ns < deadline_ns) {
        for (&catalog.results) |*ring| {
            if (ring.tryDequeue()) |r| break :outer r;
        }
        sleepNs(step_ns);
        waited_ns += step_ns;
    } else {
        return error.WorkerDidNotRespond;
    };

    try testing.expectEqualStrings("background", result.entry_name);
    try testing.expectEqual(@as(?DecodedPayload, null), result.decoded);
    try testing.expectEqual(@as(?anyerror, error.ImageBackendNotInitialized), result.err);
}

test "deinit with a pending acquire shuts down cleanly" {
    var catalog = AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.register("background", .image, dummy_file_type, dummy_bytes);
    _ = try catalog.acquire("background");
    // Intentionally do not drain — deinit must join the worker and
    // drop any in-flight results without deadlocking or leaking.
}
