//! T3 — tilemap Z-interleave by named layer binding: interleave order,
//! binding resolution (implicit / explicit / partial), back-compat, and the
//! comptime capability gates.
//!
//! Per-camera cull + per-camera background + ghost-reap live in
//! `tilemap_percamera_test.zig`; both files share the renderer mocks and
//! fixtures in `tilemap_interleave_support.zig`.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");

const s = @import("tilemap_interleave_support.zig");
const MockBackend = s.MockBackend;
const InterleaveGame = s.InterleaveGame;
const BadLayerGame = s.BadLayerGame;
const OldHookGame = s.OldHookGame;
const layerSentinel = s.layerSentinel;
const sentinelIndex = s.sentinelIndex;
const tileDrawsInRange = s.tileDrawsInRange;
const totalTileDraws = s.totalTileDraws;
const terrain_canopy_tmx = s.terrain_canopy_tmx;
const ground_tmx = s.ground_tmx;
const terrain_foliage_tmx = s.terrain_foliage_tmx;
const fake_png = s.fake_png;

test "the hook-capable renderer enables the T3 interleave path" {
    try testing.expect(InterleaveGame().tilemap_supported);
    try testing.expect(InterleaveGame().tilemap_interleave_supported);
    // HookRender exposes the dual-hook `renderWithLayerHooks` → the per-camera
    // background path is on.
    try testing.expect(InterleaveGame().tilemap_percamera_background_supported);
}

test "gate rejects a renderWithLayerHook renderer whose Layer is not a config enum" {
    // The tilemap seam IS present (T2 works), but `Layer = void` → the
    // strengthened interleave gate is OFF, so the engine uses the T2
    // whole-stack background path (never analyzing `stringToEnum(void, …)`).
    const G = BadLayerGame();
    try testing.expect(G.tilemap_supported);
    try testing.expect(!G.tilemap_interleave_supported);

    // And it still renders as a valid T2 game: a ground tilemap draws its
    // whole stack on the non-interleave path with no crash.
    var game = G.init(testing.allocator);
    defer game.deinit();
    try game.addEmbeddedTilemapAsset("g.tmx", ground_tmx);
    try game.addEmbeddedTilemapAsset("tiles.png", fake_png);
    const e = game.createEntity();
    game.addTilemap(e, .{ .asset_name = "g.tmx" });

    MockBackend.initMock(testing.allocator);
    defer MockBackend.deinitMock();
    game.render();
    // 6 tiles from the single `ground` layer, whole-stack background.
    try testing.expectEqual(@as(usize, 6), totalTileDraws(MockBackend.getDrawCalls()));
}

test "gate: a renderWithLayerHook-only renderer keeps interleave but NOT per-camera background" {
    const G = OldHookGame();
    try testing.expect(G.tilemap_supported);
    try testing.expect(G.tilemap_interleave_supported);
    // No `renderWithLayerHooks` → the per-camera background gate is OFF, so the
    // engine uses the single-primary `renderTilemapBackground` fallback.
    try testing.expect(!G.tilemap_percamera_background_supported);
}

test "bound .tmx layers interleave: terrain below, canopy above a sprite layer between them" {
    const G = InterleaveGame();
    var game = G.init(testing.allocator);
    defer game.deinit();
    try game.addEmbeddedTilemapAsset("tc.tmx", terrain_canopy_tmx);
    try game.addEmbeddedTilemapAsset("tiles.png", fake_png);

    const e = game.createEntity();
    game.setPosition(e, .{ .x = 0, .y = 0 });
    game.addTilemap(e, .{ .asset_name = "tc.tmx" });

    MockBackend.initMock(testing.allocator);
    defer MockBackend.deinitMock();
    game.render();

    const calls = MockBackend.getDrawCalls();
    const i_terrain = sentinelIndex(calls, layerSentinel(.terrain)).?;
    const i_actors = sentinelIndex(calls, layerSentinel(.actors)).?;
    const i_canopy = sentinelIndex(calls, layerSentinel(.canopy)).?;
    const i_hud = sentinelIndex(calls, layerSentinel(.hud)).?;

    // Sprite-layer sentinels appear in z-order.
    try testing.expect(i_terrain < i_actors);
    try testing.expect(i_actors < i_canopy);
    try testing.expect(i_canopy < i_hud);

    // NOTHING is drawn before the terrain sprite pass: both `.tmx` layers are
    // BOUND, so the pre-sprite background pass draws nothing — proof the tiles
    // are interleaved, not sitting in the T2 background.
    try testing.expectEqual(@as(usize, 0), tileDrawsInRange(calls, 0, i_terrain));

    // `terrain` (6 tiles) draws at the terrain layer — BELOW the `actors`
    // sprite layer (between the terrain and actors sentinels).
    try testing.expectEqual(@as(usize, 6), tileDrawsInRange(calls, i_terrain, i_actors));
    // No tiles bind to the `actors` layer.
    try testing.expectEqual(@as(usize, 0), tileDrawsInRange(calls, i_actors, i_canopy));
    // `canopy` (2 tiles) draws at the canopy layer — ABOVE the `actors`
    // sprite layer (between the canopy and hud sentinels).
    try testing.expectEqual(@as(usize, 2), tileDrawsInRange(calls, i_canopy, i_hud));
}

test "back-compat: an unbound tilemap (no name match, no binding) renders as the T2 pre-sprite background" {
    const G = InterleaveGame();
    var game = G.init(testing.allocator);
    defer game.deinit();
    try game.addEmbeddedTilemapAsset("g.tmx", ground_tmx);
    try game.addEmbeddedTilemapAsset("tiles.png", fake_png);

    const e = game.createEntity();
    game.setPosition(e, .{ .x = 0, .y = 0 });
    game.addTilemap(e, .{ .asset_name = "g.tmx" });

    MockBackend.initMock(testing.allocator);
    defer MockBackend.deinitMock();
    game.render();

    const calls = MockBackend.getDrawCalls();
    const i_terrain = sentinelIndex(calls, layerSentinel(.terrain)).?;

    // The whole `ground` stack (6 tiles) draws BEFORE the first sprite layer's
    // pass — exactly the T2 pre-sprite background order, unchanged.
    try testing.expectEqual(@as(usize, 6), tileDrawsInRange(calls, 0, i_terrain));
    try testing.expectEqual(@as(usize, 6), totalTileDraws(calls));
    // No tile is interleaved after any sprite pass.
    try testing.expectEqual(@as(usize, 0), tileDrawsInRange(calls, i_terrain, calls.len));
}

test "partial binding: the name-matching layer interleaves, the unmatched layer stays in the background" {
    const G = InterleaveGame();
    var game = G.init(testing.allocator);
    defer game.deinit();
    try game.addEmbeddedTilemapAsset("tf.tmx", terrain_foliage_tmx);
    try game.addEmbeddedTilemapAsset("tiles.png", fake_png);

    const e = game.createEntity();
    game.setPosition(e, .{ .x = 0, .y = 0 });
    // No explicit bindings: `terrain` implicitly binds (name match), `foliage`
    // matches no engine layer → unbound → background.
    game.addTilemap(e, .{ .asset_name = "tf.tmx" });

    MockBackend.initMock(testing.allocator);
    defer MockBackend.deinitMock();
    game.render();

    const calls = MockBackend.getDrawCalls();
    const i_terrain = sentinelIndex(calls, layerSentinel(.terrain)).?;
    const i_actors = sentinelIndex(calls, layerSentinel(.actors)).?;

    // `foliage` (3 tiles, unbound) draws pre-sprite (background).
    try testing.expectEqual(@as(usize, 3), tileDrawsInRange(calls, 0, i_terrain));
    // `terrain` (6 tiles, bound) interleaves at the terrain layer.
    try testing.expectEqual(@as(usize, 6), tileDrawsInRange(calls, i_terrain, i_actors));
    try testing.expectEqual(@as(usize, 9), totalTileDraws(calls));
}

test "explicit layer_bindings override: foliage binds to the canopy engine layer" {
    const G = InterleaveGame();
    var game = G.init(testing.allocator);
    defer game.deinit();
    try game.addEmbeddedTilemapAsset("tf.tmx", terrain_foliage_tmx);
    try game.addEmbeddedTilemapAsset("tiles.png", fake_png);

    const e = game.createEntity();
    game.setPosition(e, .{ .x = 0, .y = 0 });
    // Explicitly bind the non-name-matching `foliage` layer to `canopy`.
    const bindings = [_]engine.TilemapLayerBinding{
        .{ .tmx_layer = "foliage", .engine_layer = "canopy" },
    };
    game.addTilemap(e, .{ .asset_name = "tf.tmx", .layer_bindings = &bindings });

    MockBackend.initMock(testing.allocator);
    defer MockBackend.deinitMock();
    game.render();

    const calls = MockBackend.getDrawCalls();
    const i_terrain = sentinelIndex(calls, layerSentinel(.terrain)).?;
    const i_actors = sentinelIndex(calls, layerSentinel(.actors)).?;
    const i_canopy = sentinelIndex(calls, layerSentinel(.canopy)).?;
    const i_hud = sentinelIndex(calls, layerSentinel(.hud)).?;

    // Nothing pre-sprite now: both layers are bound (terrain implicitly,
    // foliage via the explicit override).
    try testing.expectEqual(@as(usize, 0), tileDrawsInRange(calls, 0, i_terrain));
    // `terrain` at the terrain layer (below `actors`).
    try testing.expectEqual(@as(usize, 6), tileDrawsInRange(calls, i_terrain, i_actors));
    // `foliage` at the canopy layer (above `actors`), honoring the override.
    try testing.expectEqual(@as(usize, 3), tileDrawsInRange(calls, i_canopy, i_hud));
}

test "#709 split-screen: bound tilemap layers render once per active camera" {
    const G = InterleaveGame();
    var game = G.init(testing.allocator);
    defer game.deinit();
    try game.addEmbeddedTilemapAsset("tc.tmx", terrain_canopy_tmx);
    try game.addEmbeddedTilemapAsset("tiles.png", fake_png);

    const e = game.createEntity();
    game.setPosition(e, .{ .x = 0, .y = 0 });
    game.addTilemap(e, .{ .asset_name = "tc.tmx" });

    // Single camera: 6 (terrain) + 2 (canopy) = 8 interleaved tile draws.
    {
        game.renderer.active_cameras = 1;
        MockBackend.initMock(testing.allocator);
        defer MockBackend.deinitMock();
        game.render();
        try testing.expectEqual(@as(usize, 8), totalTileDraws(MockBackend.getDrawCalls()));
    }

    // Two active cameras (split-screen): the per-layer hook fires once per
    // camera, so the bound layers render twice — 16 tile draws.
    {
        game.renderer.active_cameras = 2;
        MockBackend.initMock(testing.allocator);
        defer MockBackend.deinitMock();
        game.render();
        const calls = MockBackend.getDrawCalls();
        try testing.expectEqual(@as(usize, 16), totalTileDraws(calls));
        // The canopy sprite pass ran once per camera too.
        var canopy_passes: usize = 0;
        for (calls) |c| {
            if (c.texture_id == layerSentinel(.canopy)) canopy_passes += 1;
        }
        try testing.expectEqual(@as(usize, 2), canopy_passes);
    }
}
