//! T3 per-camera correctness: each active camera culls its tilemap draws to
//! its OWN world rect (#711 P1), the UNBOUND background renders per active
//! camera (#709), and ghost reaping is a PRE-render step — not a per-camera
//! draw-hook side effect (#712).
//!
//! Shares the renderer mocks + fixtures with `tilemap_interleave_test.zig`
//! via `tilemap_interleave_support.zig`.

const std = @import("std");
const testing = std.testing;

const s = @import("tilemap_interleave_support.zig");
const MockBackend = s.MockBackend;
const InterleaveGame = s.InterleaveGame;
const layerSentinel = s.layerSentinel;
const sentinelIndex = s.sentinelIndex;
const totalTileDraws = s.totalTileDraws;
const tileset_handle = s.tileset_handle;
const buildFullTmx = s.buildFullTmx;
const terrain_canopy_tmx = s.terrain_canopy_tmx;
const fake_png = s.fake_png;

test "#711 P1: each camera culls interleaved tiles to ITS world rect, not the world origin" {
    const fmax = std.math.floatMax(f32);
    const G = InterleaveGame();
    var game = G.init(testing.allocator);
    defer game.deinit();

    // A large map: 400 tiles wide (6400 world px) and 50 tall (800 world px >
    // the 600 screen height, so the map's screen offset `off_y` is NEGATIVE —
    // the case that made a naive "draw everything" impossible). Both layer
    // names match a WORLD engine layer → implicitly bound → interleave path
    // (no single-camera background involved).
    const big = try buildFullTmx(testing.allocator, 400, 50, &.{ "terrain", "canopy" });
    defer testing.allocator.free(big);
    try game.addEmbeddedTilemapAsset("big.tmx", big);
    try game.addEmbeddedTilemapAsset("tiles.png", fake_png);

    const e = game.createEntity();
    game.setPosition(e, .{ .x = 0, .y = 0 });
    game.addTilemap(e, .{ .asset_name = "big.tmx" });

    // ── Split-screen: two cameras at FAR-APART world positions ──
    // Camera 0 sits near the origin; camera 1 is panned to x≈5000. Each has a
    // 200×200 world view. Before #711 both culled at the world origin (so
    // camera 1 drew the wrong tiles / nothing in its region); now each culls
    // to its OWN viewport.
    {
        game.renderer.active_cameras = 2;
        game.renderer.cameras[0] = .{ .x = 100, .y = 100, .view_w = 200, .view_h = 200 };
        game.renderer.cameras[1] = .{ .x = 5000, .y = 100, .view_w = 200, .view_h = 200 };

        MockBackend.initMock(testing.allocator);
        defer MockBackend.deinitMock();
        game.render();
        const calls = MockBackend.getDrawCalls();

        // The mock draws camera 0's whole layer stack, then camera 1's — so
        // camera 1's pass begins at the SECOND `terrain` sprite-pass sentinel.
        var first_terrain: ?usize = null;
        var second_terrain: ?usize = null;
        for (calls, 0..) |c, i| {
            if (c.texture_id != layerSentinel(.terrain)) continue;
            if (first_terrain == null) {
                first_terrain = i;
            } else {
                second_terrain = i;
                break;
            }
        }
        try testing.expect(first_terrain != null and second_terrain != null);

        // dest.x per camera segment (camera_x = 0, so dest.x is the tile's
        // world x + centre offset — a faithful proxy for which columns drew).
        var c0_max: f32 = -fmax;
        var c1_min: f32 = fmax;
        var c0_tiles: usize = 0;
        var c1_tiles: usize = 0;
        for (calls, 0..) |c, i| {
            if (c.texture_id != tileset_handle) continue;
            if (i >= first_terrain.? and i < second_terrain.?) {
                c0_tiles += 1;
                c0_max = @max(c0_max, c.dest.x);
            } else if (i >= second_terrain.?) {
                c1_tiles += 1;
                c1_min = @min(c1_min, c.dest.x);
            }
        }

        // Both cameras drew tiles…
        try testing.expect(c0_tiles > 0);
        try testing.expect(c1_tiles > 0);
        // …camera 0 near the origin…
        try testing.expect(c0_max < 1000);
        // …and camera 1 in ITS far region (x≈5000), NOT the world origin —
        // this is the exact regression (`c1_min` would be ≈0 pre-#711).
        try testing.expect(c1_min > 4000);
    }

    // ── Single panned camera on the same large map draws its own region ──
    {
        game.renderer.active_cameras = 1;
        game.renderer.cameras[0] = .{ .x = 5000, .y = 100, .view_w = 200, .view_h = 200 };

        MockBackend.initMock(testing.allocator);
        defer MockBackend.deinitMock();
        game.render();

        var tiles: usize = 0;
        var min_x: f32 = fmax;
        var max_x: f32 = -fmax;
        for (MockBackend.getDrawCalls()) |c| {
            if (c.texture_id != tileset_handle) continue;
            tiles += 1;
            min_x = @min(min_x, c.dest.x);
            max_x = @max(max_x, c.dest.x);
        }
        // Draws the tiles around x≈5000 (its viewport) and nothing at the
        // origin — the panned camera sees what it's actually looking at.
        try testing.expect(tiles > 0);
        try testing.expect(min_x > 4000);
        try testing.expect(max_x < 6000);
    }
}

test "#709 split-screen: UNBOUND background renders PER active camera, culled to its rect" {
    const fmax = std.math.floatMax(f32);
    const G = InterleaveGame();
    var game = G.init(testing.allocator);
    defer game.deinit();

    // A large map with a SINGLE `ground` layer — name matches NO engine layer
    // and there is no explicit binding, so it is UNBOUND → the pre-sprite
    // BACKGROUND (on_before_layers). No `.tmx` layer is drawn by the after-hook,
    // so every tile draw here comes from the per-camera background.
    const big = try buildFullTmx(testing.allocator, 400, 50, &.{"ground"});
    defer testing.allocator.free(big);
    try game.addEmbeddedTilemapAsset("bg.tmx", big);
    try game.addEmbeddedTilemapAsset("tiles.png", fake_png);

    const e = game.createEntity();
    game.setPosition(e, .{ .x = 0, .y = 0 });
    game.addTilemap(e, .{ .asset_name = "bg.tmx" });

    // Two split-screen cameras far apart: camera 0 near the origin, camera 1
    // panned to x≈5000. Pre-#709 the background drew ONCE through the primary
    // camera, so camera 1's viewport showed the primary's terrain (or nothing);
    // now the before-hook fires per active camera, each culled to its own rect.
    game.renderer.active_cameras = 2;
    game.renderer.cameras[0] = .{ .x = 100, .y = 100, .view_w = 200, .view_h = 200 };
    game.renderer.cameras[1] = .{ .x = 5000, .y = 100, .view_w = 200, .view_h = 200 };

    MockBackend.initMock(testing.allocator);
    defer MockBackend.deinitMock();
    game.render();
    const calls = MockBackend.getDrawCalls();

    // The mock draws camera 0's full pass (background THEN layer stack) then
    // camera 1's, so camera 1's segment begins at the SECOND `terrain`
    // sprite-pass sentinel. Camera 0's background tiles precede the FIRST
    // sentinel; camera 1's follow it.
    const first_terrain = sentinelIndex(calls, layerSentinel(.terrain)).?;

    var c0_tiles: usize = 0;
    var c0_max: f32 = -fmax;
    var c1_tiles: usize = 0;
    var c1_min: f32 = fmax;
    for (calls, 0..) |c, i| {
        if (c.texture_id != tileset_handle) continue;
        if (i < first_terrain) {
            c0_tiles += 1;
            c0_max = @max(c0_max, c.dest.x);
        } else {
            c1_tiles += 1;
            c1_min = @min(c1_min, c.dest.x);
        }
    }

    // BOTH viewports drew the background (pre-#709: camera 1 would draw none)…
    try testing.expect(c0_tiles > 0);
    try testing.expect(c1_tiles > 0);
    // …camera 0's background near the origin…
    try testing.expect(c0_max < 1000);
    // …and camera 1's background in ITS far region (x≈5000), not the origin.
    try testing.expect(c1_min > 4000);
}

test "#712 per-camera path: a removed Tilemap is reaped BEFORE render (no unloadTexture inside the hook)" {
    const G = InterleaveGame();
    var game = G.init(testing.allocator);
    defer game.deinit();
    try game.addEmbeddedTilemapAsset("tc.tmx", terrain_canopy_tmx);
    try game.addEmbeddedTilemapAsset("tiles.png", fake_png);

    const e = game.createEntity();
    game.setPosition(e, .{ .x = 0, .y = 0 });
    game.addTilemap(e, .{ .asset_name = "tc.tmx" });
    try testing.expect(game.tilemapRuntime(e) != null);
    try testing.expectEqual(@as(usize, 1), game.renderer.textures.count());

    // Strip the component the "wrong" way (generic removeComponent) — the
    // side-table runtime is now a ghost that must be reaped, not drawn.
    game.removeComponent(e, G.TilemapComp);

    // Split-screen: a per-camera reap (the pre-#712 bug) would free the runtime
    // and unload its texture TWICE, both INSIDE gfx's render loop.
    game.renderer.active_cameras = 2;
    game.renderer.unloads_during_render = 0;

    MockBackend.initMock(testing.allocator);
    defer MockBackend.deinitMock();
    game.render();

    // The ghost was reaped: runtime freed, texture unloaded, nothing drawn.
    try testing.expect(game.tilemapRuntime(e) == null);
    try testing.expectEqual(@as(usize, 0), game.renderer.textures.count());
    try testing.expectEqual(@as(usize, 0), totalTileDraws(MockBackend.getDrawCalls()));
    // The unload ran as a PRE-render step, NOT inside a per-camera draw hook
    // (pre-#712 it ran in the hook, once PER active camera → 2 here).
    try testing.expectEqual(@as(usize, 0), game.renderer.unloads_during_render);
}
