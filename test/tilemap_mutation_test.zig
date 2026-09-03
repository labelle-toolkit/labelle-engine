//! Runtime tile mutation (#825) — `Game.setTile` / `Game.setTiles` /
//! `Game.tilemapLayerSize`.
//!
//! The `Tilemap` component used to be closed to a procedurally generated
//! map: the only ways to get generated tiles on screen were to synthesise
//! `.tmx` XML at runtime (leaking a program-lifetime asset registration per
//! regeneration) or to spawn one sprite entity per cell. These tests prove
//! the third way — writing straight into the decoded map's tile grid, which
//! gfx's IMMEDIATE-mode tilemap pass re-reads every frame, so no dirty
//! tracking and no labelle-gfx change are involved.
//!
//! They also PIN the known limitation: mutations are lost across save/load,
//! because the save channel persists only `asset_name` and load rehydrates
//! by re-decoding the `.tmx` (see the header of `src/tilemap.zig`).
//!
//! Shares the renderer mocks + fixtures with `tilemap_interleave_test.zig`
//! via `tilemap_interleave_support.zig`.

const std = @import("std");
const testing = std.testing;

const engine = @import("engine");
const core = @import("labelle-core");

const s = @import("tilemap_interleave_support.zig");
const MockBackend = s.MockBackend;
const InterleaveGame = s.InterleaveGame;
const totalTileDraws = s.totalTileDraws;
const ground_tmx = s.ground_tmx;
const terrain_foliage_tmx = s.terrain_foliage_tmx;
const fake_png = s.fake_png;

/// A 3×2 `ground` map with all six cells populated (gids 1..6).
fn groundGame(game: anytype) !void {
    try game.addEmbeddedTilemapAsset("level.tmx", ground_tmx);
    try game.addEmbeddedTilemapAsset("tiles.png", fake_png);
}

/// Read a tile back out of the decoded map — the ground truth the mutation
/// API writes into. Masks the flip bits (gfx's `TileLayer.getTile`).
fn tileAt(game: anytype, entity: u32, layer: usize, x: usize, y: usize) u32 {
    return game.tilemapRuntime(entity).?.map.tile_layers[layer].getTile(x, y);
}

/// Same, but RAW — flip bits included.
fn rawTileAt(game: anytype, entity: u32, layer: usize, x: usize, y: usize) u32 {
    return game.tilemapRuntime(entity).?.map.tile_layers[layer].getTileRaw(x, y);
}

// ── setTile ─────────────────────────────────────────────────────────────

test "setTile writes one cell of the named layer" {
    const G = InterleaveGame();
    var game = G.init(testing.allocator);
    defer game.deinit();
    try groundGame(&game);

    const e = game.createEntity();
    game.addTilemap(e, .{ .asset_name = "level.tmx" });

    try testing.expectEqual(@as(u32, 5), tileAt(&game, e, 0, 1, 1));
    game.setTile(e, "ground", 1, 1, 7);
    try testing.expectEqual(@as(u32, 7), tileAt(&game, e, 0, 1, 1));

    // Neighbours are untouched — the write is exactly one cell.
    try testing.expectEqual(@as(u32, 4), tileAt(&game, e, 0, 0, 1));
    try testing.expectEqual(@as(u32, 6), tileAt(&game, e, 0, 2, 1));
    try testing.expectEqual(@as(u32, 2), tileAt(&game, e, 0, 1, 0));
}

test "setTile gid 0 clears a cell and it stops drawing" {
    const G = InterleaveGame();
    var game = G.init(testing.allocator);
    defer game.deinit();
    try groundGame(&game);

    const e = game.createEntity();
    game.setPosition(e, .{ .x = 0, .y = 0 });
    game.addTilemap(e, .{ .asset_name = "level.tmx" });

    const before = blk: {
        MockBackend.initMock(testing.allocator);
        defer MockBackend.deinitMock();
        game.render();
        break :blk totalTileDraws(MockBackend.getDrawCalls());
    };
    try testing.expectEqual(@as(usize, 6), before);

    game.setTile(e, "ground", 0, 0, 0);

    // No re-acquire, no dirty flag: the immediate-mode pass re-reads the
    // grid, so the very next frame draws one tile fewer.
    const after = blk: {
        MockBackend.initMock(testing.allocator);
        defer MockBackend.deinitMock();
        game.render();
        break :blk totalTileDraws(MockBackend.getDrawCalls());
    };
    try testing.expectEqual(before - 1, after);
}

test "setTile preserves the raw TMX flip bits of the gid it is given" {
    const G = InterleaveGame();
    var game = G.init(testing.allocator);
    defer game.deinit();
    try groundGame(&game);

    const e = game.createEntity();
    game.addTilemap(e, .{ .asset_name = "level.tmx" });

    const flipped_h: u32 = 3 | 0x80000000;
    game.setTile(e, "ground", 2, 0, flipped_h);

    // Stored verbatim…
    try testing.expectEqual(flipped_h, rawTileAt(&game, e, 0, 2, 0));
    // …and the masked view is still the plain gid, so the draw pass decodes
    // the flip itself exactly as it does for a `.tmx`-authored flip.
    try testing.expectEqual(@as(u32, 3), tileAt(&game, e, 0, 2, 0));
}

test "setTile targets layers BY NAME, not by index" {
    const G = InterleaveGame();
    var game = G.init(testing.allocator);
    defer game.deinit();
    try game.addEmbeddedTilemapAsset("two.tmx", terrain_foliage_tmx);
    try game.addEmbeddedTilemapAsset("tiles.png", fake_png);

    const e = game.createEntity();
    game.addTilemap(e, .{ .asset_name = "two.tmx" });

    // `foliage` is the SECOND layer in document order.
    game.setTile(e, "foliage", 0, 0, 8);
    try testing.expectEqual(@as(u32, 8), tileAt(&game, e, 1, 0, 0));
    // The first layer (`terrain`) kept its authored gid.
    try testing.expectEqual(@as(u32, 1), tileAt(&game, e, 0, 0, 0));
}

// ── setTile failure modes (no-op + warn, never a crash) ─────────────────

test "setTile out of bounds writes nothing" {
    const G = InterleaveGame();
    var game = G.init(testing.allocator);
    defer game.deinit();
    try groundGame(&game);

    const e = game.createEntity();
    game.addTilemap(e, .{ .asset_name = "level.tmx" });

    game.setTile(e, "ground", 3, 0, 9); // x == width
    game.setTile(e, "ground", 0, 2, 9); // y == height
    game.setTile(e, "ground", 9999, 9999, 9);

    // The authored grid is intact — an out-of-range write must not wrap
    // into a neighbouring row (the classic `y * width + x` bug).
    const expected = [_]u32{ 1, 2, 3, 4, 5, 6 };
    for (expected, 0..) |gid, i| {
        try testing.expectEqual(gid, tileAt(&game, e, 0, i % 3, i / 3));
    }
}

test "setTile on an unknown layer name writes nothing" {
    const G = InterleaveGame();
    var game = G.init(testing.allocator);
    defer game.deinit();
    try groundGame(&game);

    const e = game.createEntity();
    game.addTilemap(e, .{ .asset_name = "level.tmx" });

    game.setTile(e, "no_such_layer", 0, 0, 9);
    try testing.expectEqual(@as(u32, 1), tileAt(&game, e, 0, 0, 0));
}

test "setTile on an entity with no tilemap runtime is a no-op" {
    const G = InterleaveGame();
    var game = G.init(testing.allocator);
    defer game.deinit();
    try groundGame(&game);

    // A bare entity, and one whose asset never resolved (component attached,
    // no runtime) — both must be survivable no-ops, not a crash.
    const bare = game.createEntity();
    game.setTile(bare, "ground", 0, 0, 9);

    const missing = game.createEntity();
    game.addTilemap(missing, .{ .asset_name = "does_not_exist.tmx" });
    try testing.expect(game.tilemapRuntime(missing) == null);
    game.setTile(missing, "ground", 0, 0, 9);
}

// ── setTiles (bulk) ─────────────────────────────────────────────────────

test "setTiles replaces the whole grid in one call" {
    const G = InterleaveGame();
    var game = G.init(testing.allocator);
    defer game.deinit();
    try groundGame(&game);

    const e = game.createEntity();
    game.addTilemap(e, .{ .asset_name = "level.tmx" });

    // What a generator produces: a row-major `[]u32` sized to the layer.
    const size = game.tilemapLayerSize(e, "ground").?;
    try testing.expectEqual(@as(u32, 3), size.width);
    try testing.expectEqual(@as(u32, 2), size.height);

    const generated = [_]u32{ 8, 7, 6, 5, 4, 3 };
    game.setTiles(e, "ground", &generated);

    for (generated, 0..) |gid, i| {
        try testing.expectEqual(gid, tileAt(&game, e, 0, i % 3, i / 3));
    }
}

test "setTiles is row-major (y * width + x)" {
    const G = InterleaveGame();
    var game = G.init(testing.allocator);
    defer game.deinit();
    try groundGame(&game);

    const e = game.createEntity();
    game.addTilemap(e, .{ .asset_name = "level.tmx" });

    // Exactly one non-zero cell, at index 4 → (x=1, y=1).
    game.setTiles(e, "ground", &[_]u32{ 0, 0, 0, 0, 5, 0 });
    try testing.expectEqual(@as(u32, 5), tileAt(&game, e, 0, 1, 1));
    try testing.expectEqual(@as(u32, 0), tileAt(&game, e, 0, 1, 0));
    try testing.expectEqual(@as(u32, 0), tileAt(&game, e, 0, 0, 1));
}

test "setTiles rejects a wrong-length slice WHOLESALE — no partial write" {
    const G = InterleaveGame();
    var game = G.init(testing.allocator);
    defer game.deinit();
    try groundGame(&game);

    const e = game.createEntity();
    game.addTilemap(e, .{ .asset_name = "level.tmx" });

    game.setTiles(e, "ground", &[_]u32{ 9, 9, 9 }); // too short
    game.setTiles(e, "ground", &[_]u32{ 9, 9, 9, 9, 9, 9, 9 }); // too long
    game.setTiles(e, "ground", &[_]u32{}); // empty

    // Not even the cells a "copy what fits" implementation would have
    // written are touched.
    const expected = [_]u32{ 1, 2, 3, 4, 5, 6 };
    for (expected, 0..) |gid, i| {
        try testing.expectEqual(gid, tileAt(&game, e, 0, i % 3, i / 3));
    }
}

test "setTiles on an unknown layer / missing runtime is a no-op" {
    const G = InterleaveGame();
    var game = G.init(testing.allocator);
    defer game.deinit();
    try groundGame(&game);

    const e = game.createEntity();
    game.addTilemap(e, .{ .asset_name = "level.tmx" });

    game.setTiles(e, "no_such_layer", &[_]u32{ 9, 9, 9, 9, 9, 9 });
    try testing.expectEqual(@as(u32, 1), tileAt(&game, e, 0, 0, 0));

    const bare = game.createEntity();
    game.setTiles(bare, "ground", &[_]u32{ 9, 9, 9, 9, 9, 9 });
}

test "setTiles accepts a slice that ALIASES the live grid" {
    const G = InterleaveGame();
    var game = G.init(testing.allocator);
    defer game.deinit();
    try groundGame(&game);

    const e = game.createEntity();
    game.addTilemap(e, .{ .asset_name = "level.tmx" });

    // `tilemapRuntime` is public, so "read the grid, tweak it in place,
    // push it back" is a reachable caller shape. `@memcpy` would trip its
    // non-aliasing precondition here (panic in safety builds, UB when
    // optimized) — codex #829.
    const live = game.tilemapRuntime(e).?.map.tile_layers[0].data;
    live[0] = 9;
    game.setTiles(e, "ground", live); // dest and source are the SAME slice

    // The self-assignment is a no-op that leaves the grid intact.
    try testing.expectEqual(@as(u32, 9), tileAt(&game, e, 0, 0, 0));
    try testing.expectEqual(@as(u32, 2), tileAt(&game, e, 0, 1, 0));
    try testing.expectEqual(@as(u32, 6), tileAt(&game, e, 0, 2, 1));
}

test "a fully generated grid draws every non-zero cell on the next frame" {
    const G = InterleaveGame();
    var game = G.init(testing.allocator);
    defer game.deinit();
    try groundGame(&game);

    const e = game.createEntity();
    game.setPosition(e, .{ .x = 0, .y = 0 });
    game.addTilemap(e, .{ .asset_name = "level.tmx" });

    // A "generator" that filled only half the grid.
    game.setTiles(e, "ground", &[_]u32{ 1, 0, 1, 0, 1, 0 });

    MockBackend.initMock(testing.allocator);
    defer MockBackend.deinitMock();
    game.render();
    try testing.expectEqual(@as(usize, 3), totalTileDraws(MockBackend.getDrawCalls()));
}

// ── tilemapLayerSize ────────────────────────────────────────────────────

test "tilemapLayerSize reports the layer grid, null for anything unknown" {
    const G = InterleaveGame();
    var game = G.init(testing.allocator);
    defer game.deinit();
    try groundGame(&game);

    const e = game.createEntity();
    game.addTilemap(e, .{ .asset_name = "level.tmx" });

    const size = game.tilemapLayerSize(e, "ground").?;
    try testing.expectEqual(@as(u32, 3), size.width);
    try testing.expectEqual(@as(u32, 2), size.height);

    try testing.expect(game.tilemapLayerSize(e, "no_such_layer") == null);
    try testing.expect(game.tilemapLayerSize(game.createEntity(), "ground") == null);
}

// ── The documented limitation: mutations do NOT persist ─────────────────

test "LIMITATION: runtime tile mutations are LOST across save/load" {
    const G = InterleaveGame();
    const filename = "test_tilemap_mutation_save.json";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, filename) catch {};

    {
        var game = G.init(testing.allocator);
        defer game.deinit();
        try groundGame(&game);
        const e = game.createEntity();
        game.addTilemap(e, .{ .asset_name = "level.tmx" });
        game.setTiles(e, "ground", &[_]u32{ 8, 8, 8, 8, 8, 8 });
        try testing.expectEqual(@as(u32, 8), tileAt(&game, e, 0, 0, 0));
        try game.saveGameState(filename);
    }

    // The save channel carries only `asset_name` — the generated grid never
    // reaches the snapshot.
    {
        const json = try std.Io.Dir.cwd().readFileAlloc(
            std.testing.io,
            filename,
            testing.allocator,
            .limited(1 << 20),
        );
        defer testing.allocator.free(json);
        try testing.expect(std.mem.indexOf(u8, json, "level.tmx") != null);
        try testing.expect(std.mem.indexOf(u8, json, "tile_layers") == null);
    }

    // Load re-decodes the `.tmx`, so the map comes back with the AUTHORED
    // tiles, not the generated ones. A game that generates its map must
    // re-apply it after load (see `setTile`'s doc comment).
    {
        var game = G.init(testing.allocator);
        defer game.deinit();
        try groundGame(&game);
        try game.loadGameState(filename);

        var found = false;
        var v = game.ecs_backend.view(.{core.Position}, .{});
        defer v.deinit();
        while (v.next()) |ent| {
            if (game.getComponent(ent, G.TilemapComp) == null) continue;
            found = true;
            try testing.expectEqual(@as(u32, 1), tileAt(&game, ent, 0, 0, 0));
            try testing.expectEqual(@as(u32, 6), tileAt(&game, ent, 0, 2, 1));
        }
        try testing.expect(found);
    }
}

test "LIMITATION: acquireTilemap re-decode discards runtime mutations" {
    const G = InterleaveGame();
    var game = G.init(testing.allocator);
    defer game.deinit();
    try groundGame(&game);

    const e = game.createEntity();
    game.addTilemap(e, .{ .asset_name = "level.tmx" });
    game.setTile(e, "ground", 0, 0, 8);
    try testing.expectEqual(@as(u32, 8), tileAt(&game, e, 0, 0, 0));

    game.acquireTilemap(e, "level.tmx"); // rebuild from the asset
    try testing.expectEqual(@as(u32, 1), tileAt(&game, e, 0, 0, 0));
}

// ── Unsupported renderer: the whole feature compiles away ───────────────

/// A renderer with no gfx tilemap seam (the `StubRender` a headless/test
/// build uses). `Game.tilemap_supported` is false, so the mutation API must
/// still COMPILE and behave as an inert no-op — the mixin's additive
/// contract for stub backends.
fn StubGame() type {
    return engine.GameConfig(
        engine.StubRender(engine.MockEcsBackend(u32).Entity),
        engine.MockEcsBackend(u32),
        engine.StubInput,
        engine.StubAudio,
        engine.StubVideo,
        engine.StubGui,
        void,
        engine.StubLogSink,
        s.EmptyComponents,
        &.{},
        void,
    );
}

test "mutation API is an inert no-op on a renderer without the tilemap seam" {
    const G = StubGame();
    try testing.expect(!G.tilemap_supported);

    var game = G.init(testing.allocator);
    defer game.deinit();

    const e = game.createEntity();
    game.addTilemap(e, .{ .asset_name = "level.tmx" });
    game.setTile(e, "ground", 0, 0, 1);
    game.setTiles(e, "ground", &[_]u32{ 1, 2, 3 });
    try testing.expect(game.tilemapLayerSize(e, "ground") == null);
}
