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

// Drag the in-source test blocks under `src/assets/` into this test
// binary so they run together with the engine integration tests.
test {
    testing.refAllDecls(engine.assets_mod);
}
