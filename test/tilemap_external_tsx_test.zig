//! External `.tsx` resolution (#834) — the third link of the chain.
//!
//! labelle-gfx#336 taught the TMX loader to resolve
//! `<tileset source="…tsx"/>` and exposed `LoadOptions.tsx_resolver` for the
//! memory path. labelle-assembler#684 embeds the `.tsx` and its image, keyed
//! by the `source` attribute exactly as written. Neither did anything in a
//! real build, because `tilemap_runtime.initInPlace` called
//! `loadFromMemoryWithBasePath` and passed no resolver — so decoding never
//! consulted the registry, the map failed, and `tilemap_mixin` swallowed the
//! error into a `log.warn` and an empty screen.
//!
//! These tests pin the wiring: the SAME provider that serves tileset images
//! also serves `.tsx` documents, because the engine keeps one registry and
//! the two callbacks have an identical signature.

const std = @import("std");
const testing = std.testing;

const s = @import("tilemap_interleave_support.zig");
const InterleaveGame = s.InterleaveGame;
const fake_png = s.fake_png;

/// A map whose tileset lives in a separate `.tsx`, referenced the way Tiled
/// writes it. Before #834 this decoded to nothing.
const external_tmx =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<map version="1.10" orientation="orthogonal" renderorder="right-down" width="3" height="2" tilewidth="16" tileheight="16" infinite="0">
    \\ <tileset firstgid="1" source="../tilesets/terrain.tsx"/>
    \\ <layer id="1" name="ground" width="3" height="2">
    \\  <data encoding="csv">
    \\1,2,3,
    \\4,5,6
    \\</data>
    \\ </layer>
    \\</map>
;

/// The referenced document. Its `<image>` is relative to the `.tsx`'s own
/// directory, which is NOT the map's — gfx rebases it, and the assembler
/// registers the rebased key.
const terrain_tsx =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<tileset name="terrain" tilewidth="16" tileheight="16" tilecount="6" columns="3">
    \\ <image source="tiles.png" width="48" height="32"/>
    \\</tileset>
;

test "an external .tsx resolves through the embedded asset registry" {
    const G = InterleaveGame();
    var game = G.init(testing.allocator);
    defer game.deinit();

    // Keyed exactly as the .tmx writes the reference — that is the contract
    // between the assembler's registration and gfx's resolver.
    try game.addEmbeddedTilemapAsset("level.tmx", external_tmx);
    try game.addEmbeddedTilemapAsset("../tilesets/terrain.tsx", terrain_tsx);
    try game.addEmbeddedTilemapAsset("../tilesets/tiles.png", fake_png);

    const e = game.createEntity();
    game.addTilemap(e, .{ .asset_name = "level.tmx" });

    // Before #834 there was no runtime at all: the decode failed with
    // error.ExternalTilesetUnsupported and was swallowed into a warning.
    const rt = game.tilemapRuntime(e) orelse return error.NoTilemapRuntime;

    try testing.expectEqual(@as(usize, 1), rt.map.tilesets.len);
    try testing.expectEqualStrings("terrain", rt.map.tilesets[0].name);
    // firstgid comes from the REFERENCING element, not from the .tsx.
    try testing.expectEqual(@as(u32, 1), rt.map.tilesets[0].firstgid);
    try testing.expectEqual(@as(u32, 3), rt.map.tilesets[0].columns);

    // The layer still decoded normally alongside the external tileset.
    try testing.expectEqual(@as(usize, 1), rt.map.tile_layers.len);
    try testing.expectEqual(@as(u32, 1), rt.map.tile_layers[0].getTile(0, 0));
    try testing.expectEqual(@as(u32, 6), rt.map.tile_layers[0].getTile(2, 1));
}

test "an unresolvable .tsx degrades to no runtime rather than crashing" {
    const G = InterleaveGame();
    var game = G.init(testing.allocator);
    defer game.deinit();

    // The .tsx is never registered. gfx has no base path to fall back to, so
    // this must fail cleanly — the mixin's documented "decode failed" path.
    try game.addEmbeddedTilemapAsset("level.tmx", external_tmx);

    const e = game.createEntity();
    game.addTilemap(e, .{ .asset_name = "level.tmx" });

    try testing.expect(game.tilemapRuntime(e) == null);
}
