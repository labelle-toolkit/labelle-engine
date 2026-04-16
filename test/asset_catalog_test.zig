//! Integration test entry point for the `src/assets/` module.
//!
//! The catalog's behavioural tests live next to the implementation
//! in `src/assets/catalog.zig`. This file pulls the module in via
//! the `engine` import so `zig build test` exercises every test
//! block under `src/assets/` (catalog + the loader / worker stubs
//! re-exported through `assets/mod.zig`).

const std = @import("std");
const testing = std.testing;

const engine = @import("engine");
const image_loader = engine.ImageLoader;

test "engine re-exports AssetCatalog and friends" {
    // Catalog round-trip via the engine-level alias to make sure the
    // module is wired into root.zig and reachable from outside.
    var catalog = engine.AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.register("background", engine.LoaderKind.image, "png", "fake-bytes");
    try testing.expect(!catalog.isReady("background"));

    const entry = try catalog.acquire("background");
    try testing.expectEqual(@as(u32, 1), entry.refcount);
    // First acquire spawns the worker and moves the entry to
    // `.queued` — the real `.ready` transition lands with #442's
    // pump() body.
    try testing.expectEqual(engine.AssetState.queued, entry.state);
    try testing.expectEqual(engine.LoaderKind.image, entry.loader_kind);

    catalog.release("background");
    try testing.expectEqual(@as(u32, 0), entry.refcount);

    // pump() is a no-op until #442; confirm the symbol is callable.
    catalog.pump();
}

test "engine.AssetCatalog progress over an empty manifest is fully ready" {
    var catalog = engine.AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    const empty: []const []const u8 = &.{};
    try testing.expect(catalog.allReady(empty));
    try testing.expectEqual(@as(f32, 1.0), catalog.progress(empty));
}

// ---------------------------------------------------------------------
// Image loader ↔ catalog integration
// ---------------------------------------------------------------------
//
// These tests exercise the full register → acquire → worker-decode →
// manual-upload → unload pipeline against a mock image backend. The
// `pump()` body is still a no-op (lands in #442) so the tests dequeue
// the worker result off the catalog's ring manually and call
// `loader.upload` / `loader.free` directly — enough to prove the
// vtable is wired end-to-end.

const IntegrationMock = struct {
    var decode_calls: u32 = 0;
    var upload_calls: u32 = 0;
    var unload_calls: u32 = 0;
    var next_tex: engine.AssetTexture = 100;

    fn reset() void {
        decode_calls = 0;
        upload_calls = 0;
        unload_calls = 0;
        next_tex = 100;
    }

    fn decodeFn(
        file_type: [:0]const u8,
        data: []const u8,
        allocator: std.mem.Allocator,
    ) anyerror!engine.DecodedImage {
        _ = file_type;
        _ = data;
        decode_calls += 1;
        // 1×1 RGBA — matches the mock-backend contract from
        // labelle-gfx tests.
        const pixels = try allocator.alloc(u8, 4);
        @memset(pixels, 0x7F);
        return .{ .pixels = pixels, .width = 1, .height = 1 };
    }

    fn uploadFn(decoded: engine.DecodedImage) anyerror!engine.AssetTexture {
        _ = decoded;
        upload_calls += 1;
        const t = next_tex;
        next_tex += 1;
        return t;
    }

    fn unloadFn(texture: engine.AssetTexture) void {
        _ = texture;
        unload_calls += 1;
    }

    const backend: engine.ImageBackend = .{
        .decode = decodeFn,
        .upload = uploadFn,
        .unload = unloadFn,
    };
};

test "image loader: catalog → worker → upload → free end to end" {
    IntegrationMock.reset();
    image_loader.setBackend(IntegrationMock.backend);
    defer image_loader.clearBackend();

    var catalog = engine.AssetCatalog.init(testing.allocator);
    defer catalog.deinit();

    try catalog.register("ship", engine.LoaderKind.image, "png", "fake-png-bytes");
    _ = try catalog.acquire("ship");

    // Spin up to 200ms waiting for the worker to publish a decoded
    // payload — `pump()` is still a no-op (#442) so we drain the
    // result ring manually.
    const deadline_ns: u64 = 200 * std.time.ns_per_ms;
    var waited_ns: u64 = 0;
    const step_ns: u64 = 1 * std.time.ns_per_ms;
    const result = outer: while (waited_ns < deadline_ns) {
        for (&catalog.results) |*ring| {
            if (ring.tryDequeue()) |r| break :outer r;
        }
        std.Thread.sleep(step_ns);
        waited_ns += step_ns;
    } else {
        return error.WorkerDidNotRespond;
    };

    try testing.expectEqualStrings("ship", result.entry_name);
    try testing.expect(result.err == null);
    try testing.expect(result.decoded != null);
    try testing.expectEqual(@as(u32, 1), IntegrationMock.decode_calls);

    const payload = result.decoded.?;
    try testing.expectEqual(@as(u32, 1), payload.image.width);
    try testing.expectEqual(@as(u32, 1), payload.image.height);
    try testing.expectEqual(@as(usize, 4), payload.image.pixels.len);

    // Emulate what pump() (#442) will do: look the entry up, check
    // refcount, call loader.upload, flip state to .ready.
    const entry = catalog.entries.getPtr("ship").?;
    try result.vtable.upload(entry, payload, testing.allocator);
    entry.decoded = null;
    entry.state = .ready;

    try testing.expect(catalog.isReady("ship"));
    try testing.expect(entry.resource != null);
    try testing.expect(entry.resource.?.image >= 100);
    try testing.expectEqual(@as(u32, 1), IntegrationMock.upload_calls);

    // Release drops refcount to zero on a `.ready` entry, so the
    // catalog dispatches `vtable.free` (#446): the backend unload
    // fires, `entry.resource` is cleared, state rewinds to
    // `.registered`.
    catalog.release("ship");
    try testing.expectEqual(@as(u32, 0), entry.refcount);
    try testing.expectEqual(@as(u32, 1), IntegrationMock.unload_calls);
    try testing.expectEqual(@as(?engine.UploadedResource, null), entry.resource);
    try testing.expectEqual(engine.AssetState.registered, entry.state);
}

test "image loader: catalog discard path frees pixels when refcount hits zero before upload" {
    IntegrationMock.reset();
    image_loader.setBackend(IntegrationMock.backend);
    defer image_loader.clearBackend();

    var catalog = engine.AssetCatalog.init(testing.allocator);

    try catalog.register("transient", engine.LoaderKind.image, "png", "fake-bytes");
    _ = try catalog.acquire("transient");

    // Wait for the worker to actually decode, so there is an
    // allocator-owned pixel buffer in flight that `deinit` MUST free
    // via `vtable.drop`. Without this we might race past decode and
    // the test would pass trivially without exercising the path.
    const deadline_ns: u64 = 200 * std.time.ns_per_ms;
    var waited_ns: u64 = 0;
    const step_ns: u64 = 1 * std.time.ns_per_ms;
    while (waited_ns < deadline_ns) : (waited_ns += step_ns) {
        if (IntegrationMock.decode_calls > 0) break;
        std.Thread.sleep(step_ns);
    }
    try testing.expectEqual(@as(u32, 1), IntegrationMock.decode_calls);

    // Drop the refcount to zero. The WorkResult with its
    // allocator-owned pixels is still sitting on the ring.
    catalog.release("transient");

    // `deinit` drains the result ring and calls
    // `vtable.drop(allocator, payload)` on everything it finds.
    // `testing.allocator` (a GPA under the hood) will flag either a
    // leak (drop forgot to free) or a double-free (drop freed twice).
    catalog.deinit();

    // Upload must NOT have been called — refcount hit zero before
    // any main-thread pump() ever ran.
    try testing.expectEqual(@as(u32, 0), IntegrationMock.upload_calls);
    try testing.expectEqual(@as(u32, 0), IntegrationMock.unload_calls);
}

// Touch every decl on `engine.assets_mod` so the engine-side module
// is semantically analyzed as part of this test binary — catches
// misuses of the public surface from outside the engine. The
// in-source test blocks under `src/assets/` run in a separate test
// binary rooted at `src/assets/mod.zig` (see `build.zig`) because
// Zig only discovers in-source tests in files that belong to the
// same module as the test binary's root, and the `test/*.zig` files
// reach the engine through a cross-module import.
test {
    testing.refAllDecls(engine.assets_mod);
}
