//! Collection-of-images tilesets (#841, companion to labelle-gfx#343).
//!
//! A Tiled tileset comes in two layouts. A **sheet** is one image sliced by
//! a uniform grid — one texture for the whole tileset. A **collection of
//! images** (`columns="0"`) has one `<image>` per `<tile>` and no sheet at
//! all, so one tileset needs N textures. `tilemap_runtime.initInPlace`
//! uploaded exactly one image per tileset from `image_source` and `continue`d
//! past any tileset that had none — i.e. past every collection tileset, which
//! therefore rendered nothing in an embedded build.
//!
//! ## Why this suite does not use the real gfx `tilemap` package
//!
//! The gfx half (`Tileset.tile_images` + `TextureResolver.resolveTileFn`)
//! lives on labelle-gfx#347, which is not released; `build.zig.zon` pins gfx
//! v1.31.0, whose `Tileset` has no `tile_images` field at all. The engine
//! reaches those types purely by reflection through the renderer plugin, so
//! the honest stand-in is a renderer seam shaped exactly like gfx's — which
//! is what `FakeGfx` (`tilemap_fake_gfx.zig`) is. `FakeGfx(true)` is the post-#343 shape,
//! `FakeGfx(false)` the pre-#343 one, and both are driven through the real
//! `Game`/`tilemap_runtime` code path.
//!
//! That pairing is the point of the gate: collection support is gated on
//! `@hasField(Tileset, "tile_images") and @hasField(Resolver, "resolveTileFn")`
//! and NOT on `supported()`/`hasReflectableSeam`, so an engine built against
//! older gfx keeps its tilemaps and merely loses collection tilesets. The
//! legacy half of this suite is what pins that.
//!
//! (The real-gfx sheet path stays covered by `tilemap_test.zig` and friends,
//! which run against the pinned gfx and exercise the `!collection_supported`
//! branch of the same code.)

const std = @import("std");
const testing = std.testing;

const engine = @import("engine");
const core = @import("labelle-core");

const GameConfig = engine.GameConfig;
const MockEcsBackend = engine.MockEcsBackend;
const StubInput = engine.StubInput;
const StubAudio = engine.StubAudio;
const StubVideo = engine.StubVideo;
const StubGui = engine.StubGui;
const StubLogSink = engine.StubLogSink;

// ── Fixtures ────────────────────────────────────────────────────────────

/// Three props, three distinct images, no sheet — `columns="0"` and one
/// `<image>` per `<tile>`, exactly as Tiled writes a collection. The
/// `<properties>` and self-closed `<tile/>` are there because Tiled emits
/// them and a `<tile>`-tracking scanner must survive both.
const collection_tmx =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<map version="1.10" orientation="orthogonal" width="3" height="2" tilewidth="16" tileheight="16">
    \\ <tileset firstgid="1" name="props" tilewidth="16" tileheight="16" columns="0" tilecount="3">
    \\  <tile id="0">
    \\   <properties><property name="solid" value="true"/></properties>
    \\   <image source="tree.png" width="32" height="48"/>
    \\  </tile>
    \\  <tile id="1">
    \\   <image source="rock.png" width="16" height="16"/>
    \\  </tile>
    \\  <tile id="2">
    \\   <image source="sign.png" width="16" height="24"/>
    \\  </tile>
    \\ </tileset>
    \\ <layer name="ground" width="3" height="2">
    \\  <data encoding="csv">
    \\1,2,3,
    \\0,0,0,
    \\</data>
    \\ </layer>
    \\</map>
;

/// Same shape, but tiles 0 and 2 name the SAME image — the case that turns
/// N tiles into N GPU uploads (and N unloads of one texture) without dedup.
const shared_source_tmx =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<map version="1.10" orientation="orthogonal" width="3" height="2" tilewidth="16" tileheight="16">
    \\ <tileset firstgid="1" name="props" tilewidth="16" tileheight="16" columns="0" tilecount="3">
    \\  <tile id="0">
    \\   <image source="tree.png" width="32" height="48"/>
    \\  </tile>
    \\  <tile id="1">
    \\   <image source="rock.png" width="16" height="16"/>
    \\  </tile>
    \\  <tile id="2">
    \\   <image source="tree.png" width="32" height="48"/>
    \\  </tile>
    \\ </tileset>
    \\ <layer name="ground" width="3" height="2">
    \\  <data encoding="csv">
    \\1,2,3,
    \\0,0,0,
    \\</data>
    \\ </layer>
    \\</map>
;

/// One collection tileset AND one ordinary sheet tileset in the same file —
/// the map that proves the sheet path is untouched by the addition.
const mixed_tmx =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<map version="1.10" orientation="orthogonal" width="3" height="2" tilewidth="16" tileheight="16">
    \\ <tileset firstgid="1" name="terrain" tilewidth="16" tileheight="16" columns="4" tilecount="8">
    \\  <image source="tiles.png" width="64" height="32"/>
    \\ </tileset>
    \\ <tileset firstgid="9" name="props" tilewidth="16" tileheight="16" columns="0" tilecount="3">
    \\  <tile id="0">
    \\   <image source="tree.png" width="32" height="48"/>
    \\  </tile>
    \\  <tile id="1"/>
    \\  <tile id="2">
    \\   <image source="rock.png" width="16" height="16"/>
    \\  </tile>
    \\ </tileset>
    \\ <layer name="ground" width="3" height="2">
    \\  <data encoding="csv">
    \\1,2,9,
    \\0,0,0,
    \\</data>
    \\ </layer>
    \\</map>
;

/// A plain sheet map — the pre-#343 baseline, used with both seam shapes.
const sheet_tmx =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<map version="1.10" orientation="orthogonal" width="3" height="2" tilewidth="16" tileheight="16">
    \\ <tileset firstgid="1" name="terrain" tilewidth="16" tileheight="16" columns="4" tilecount="8">
    \\  <image source="tiles.png" width="64" height="32"/>
    \\ </tileset>
    \\ <layer name="ground" width="3" height="2">
    \\  <data encoding="csv">
    \\1,2,3,
    \\4,5,6,
    \\</data>
    \\ </layer>
    \\</map>
;

const fake_png = "\x89PNG\r\n\x1a\n fake pixels";

// ── Upload / unload ledger ──────────────────────────────────────────────
//
// File-scope so it survives `game.deinit()` — the double-unload assertion
// has to read the ledger AFTER the renderer the game owns is gone.

var upload_count: usize = 0;
var unloads: std.ArrayList(u32) = .empty;
/// The `file_type` handed to the backend for each upload, in order. A real
/// backend dispatches its decoder on this, so a wrong one renders blank.
var file_types: std.ArrayList([]const u8) = .empty;

/// Frees the ledger AND resets it for the next test. Registered as the
/// FIRST `defer` in each test so it runs LAST — after `game.deinit()`,
/// whose unloads are exactly what the teardown test reads.
fn clearLedger() void {
    unloads.deinit(testing.allocator);
    unloads = .empty;
    for (file_types.items) |ft| testing.allocator.free(ft);
    file_types.deinit(testing.allocator);
    file_types = .empty;
    upload_count = 0;
}

fn unloadCount(id: u32) usize {
    var n: usize = 0;
    for (unloads.items) |u| {
        if (u == id) n += 1;
    }
    return n;
}

// ── A stand-in for gfx's tilemap seam (shared: `tilemap_fake_gfx.zig`) ──

const fake_gfx = @import("tilemap_fake_gfx.zig");
const FakeGfx = fake_gfx.FakeGfx;
const parseTmx = fake_gfx.parseTmx;

// ── Renderer plugin ─────────────────────────────────────────────────────

/// A `core.RenderInterface`-shaped renderer exposing the tilemap seam over
/// `FakeGfx(with_collection)`. `getTextureInfo`'s return type references
/// `self` — GENERIC, exactly like the production `GfxRendererWith` — so
/// this also keeps the v1.75.1 null-backend shape under test.
fn FakeRender(comptime with_collection: bool) type {
    return struct {
        const Self = @This();
        const Gfx = FakeGfx(with_collection);

        pub const Sprite = struct {
            sprite_name: []const u8 = "",
            visible: bool = true,
            z_index: i16 = 0,
            layer: enum { default } = .default,
        };
        pub const Shape = struct {
            shape: union(enum) {
                rectangle: struct { width: f32 = 10, height: f32 = 10 },
                circle: struct { radius: f32 = 10 },
            } = .{ .rectangle = .{} },
            color: struct { r: u8 = 255, g: u8 = 255, b: u8 = 255, a: u8 = 255 } = .{},
            visible: bool = true,
            z_index: i16 = 0,
            layer: enum { default } = .default,
        };

        pub const TileMapRendererType = Gfx.TileMapRenderer;
        pub const Inner = struct {
            pub const TextureInfo = struct { backend_texture: Gfx.Texture };
        };

        inner: Inner = .{},
        alloc: std.mem.Allocator = undefined,
        live: std.AutoHashMapUnmanaged(u32, void) = .empty,
        next_id: u32 = 1,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .alloc = allocator };
        }
        pub fn deinit(self: *Self) void {
            self.live.deinit(self.alloc);
        }

        pub fn loadTextureFromMemory(self: *Self, file_type: [:0]const u8, data: []const u8) !u32 {
            _ = data;
            // Copied: the caller frees `ft` as soon as this returns.
            const kept = testing.allocator.dupe(u8, file_type) catch @panic("OOM");
            file_types.append(testing.allocator, kept) catch @panic("OOM");
            const id = self.next_id;
            self.next_id += 1;
            try self.live.put(self.alloc, id, {});
            upload_count += 1;
            return id;
        }
        pub fn getTextureInfo(self: *const Self, id: u32) ?@TypeOf(self.inner).TextureInfo {
            if (!self.live.contains(id)) return null;
            return .{ .backend_texture = .{ .id = id } };
        }
        pub fn unloadTexture(self: *Self, id: u32) void {
            unloads.append(testing.allocator, id) catch @panic("OOM");
            _ = self.live.remove(id);
        }

        // ── core.RenderInterface no-ops ──
        pub fn trackEntity(_: *Self, _: u32, _: core.render.VisualType) void {}
        pub fn untrackEntity(_: *Self, _: u32) void {}
        pub fn markPositionDirty(_: *Self, _: u32) void {}
        pub fn markPositionDirtyWithChildren(_: *Self, comptime _: type, _: anytype, _: u32) void {}
        pub fn updateHierarchyFlag(_: *Self, _: u32, _: bool) void {}
        pub fn markVisualDirty(_: *Self, _: u32) void {}
        pub fn sync(_: *Self, comptime _: type, _: anytype) void {}
        pub fn setScreenHeight(_: *Self, _: f32) void {}
        pub fn renderGizmoDraws(_: *Self, _: []const core.gizmos.GizmoDraw) void {}
        pub fn hasEntity(_: *const Self, _: u32) bool {
            return false;
        }
        pub fn clear(_: *Self) void {}
        pub fn render(_: *Self) void {}
    };
}

const EmptyComponents = struct {
    pub fn has(comptime _: []const u8) bool {
        return false;
    }
    pub fn getType(comptime _: []const u8) type {
        return void;
    }
    pub fn names() []const []const u8 {
        return &.{};
    }
};

fn CollectionGame(comptime with_collection: bool) type {
    return GameConfig(
        FakeRender(with_collection),
        MockEcsBackend(u32),
        StubInput,
        StubAudio,
        StubVideo,
        StubGui,
        void, // Hooks
        StubLogSink,
        EmptyComponents,
        &.{}, // gizmo categories
        void, // game events
    );
}

const ModernGame = CollectionGame(true);
const LegacyGame = CollectionGame(false);

// ── Tests ───────────────────────────────────────────────────────────────

test "the post-#343 gfx seam is recognised as tilemap-capable" {
    defer clearLedger();
    try testing.expect(engine.tilemapSupported(FakeRender(true)));
    try testing.expect(ModernGame.tilemap_supported);
}

test "a collection tileset resolves one texture per tile" {
    defer clearLedger();

    var game = ModernGame.init(testing.allocator);
    defer game.deinit();
    try game.addEmbeddedTilemapAsset("level.tmx", collection_tmx);
    try game.addEmbeddedTilemapAsset("tree.png", fake_png);
    try game.addEmbeddedTilemapAsset("rock.png", fake_png);
    try game.addEmbeddedTilemapAsset("sign.png", fake_png);

    const e = game.createEntity();
    game.addTilemap(e, .{ .asset_name = "level.tmx" });

    const rt = game.tilemapRuntime(e) orelse return error.NoTilemapRuntime;

    // The tileset carries no sheet at all — before #841 that was the
    // `continue` that made it invisible.
    try testing.expectEqual(@as(usize, 1), rt.map.tilesets.len);
    try testing.expectEqualStrings("", rt.map.tilesets[0].image_source);
    try testing.expectEqual(@as(u32, 0), rt.map.tilesets[0].columns);
    try testing.expectEqual(@as(usize, 3), rt.map.tilesets[0].tile_images.len);

    // Three distinct sources → three uploads, and the flat storage covers
    // exactly the one tileset's run.
    try testing.expectEqual(@as(usize, 3), upload_count);
    try testing.expectEqualSlices(usize, &.{ 0, 3 }, rt.tile_offsets);
    try testing.expectEqual(@as(usize, 3), rt.tile_ids.len);
    try testing.expectEqual(@as(usize, 3), rt.owned_ids.len);
    for (rt.tile_ids) |id| try testing.expect(id != null);

    // gfx got a texture for every tile, through `resolveTileFn`.
    try testing.expect(rt.tm.had_tile_resolver);
    try testing.expectEqual(@as(usize, 3), rt.tm.tiles.len);
    for (rt.tm.tiles, rt.tile_ids) |resolved, uploaded| {
        try testing.expectEqual(uploaded.?, (resolved orelse return error.TileUnresolved).id);
    }
    // A collection tileset still has no sheet texture.
    try testing.expect(rt.tm.sheet[0] == null);
}

test "tiles naming the same source share ONE upload" {
    defer clearLedger();

    var game = ModernGame.init(testing.allocator);
    defer game.deinit();
    try game.addEmbeddedTilemapAsset("level.tmx", shared_source_tmx);
    try game.addEmbeddedTilemapAsset("tree.png", fake_png);
    try game.addEmbeddedTilemapAsset("rock.png", fake_png);

    const e = game.createEntity();
    game.addTilemap(e, .{ .asset_name = "level.tmx" });

    const rt = game.tilemapRuntime(e) orelse return error.NoTilemapRuntime;

    // Three tiles, two distinct sources. Without the init-time dedup this
    // is 3 — `recordTexture` caches nothing, so every call is a fresh GPU
    // texture for the same bytes.
    try testing.expectEqual(@as(usize, 2), upload_count);
    try testing.expectEqual(@as(usize, 2), rt.owned_ids.len);

    // Both tiles that name `tree.png` point at the SAME id, and both still
    // resolve — sharing must not cost the second tile its texture.
    try testing.expectEqual(@as(usize, 3), rt.tile_ids.len);
    try testing.expectEqual(rt.tile_ids[0].?, rt.tile_ids[2].?);
    try testing.expect(rt.tile_ids[1].? != rt.tile_ids[0].?);
    for (rt.tm.tiles) |resolved| try testing.expect(resolved != null);
    try testing.expectEqual(rt.tm.tiles[0].?.id, rt.tm.tiles[2].?.id);
}

test "a shared tile texture is unloaded exactly once on teardown" {
    defer clearLedger();

    var shared_id: u32 = 0;
    {
        var game = ModernGame.init(testing.allocator);
        defer game.deinit();
        try game.addEmbeddedTilemapAsset("level.tmx", shared_source_tmx);
        try game.addEmbeddedTilemapAsset("tree.png", fake_png);
        try game.addEmbeddedTilemapAsset("rock.png", fake_png);

        const e = game.createEntity();
        game.addTilemap(e, .{ .asset_name = "level.tmx" });
        const rt = game.tilemapRuntime(e) orelse return error.NoTilemapRuntime;
        shared_id = rt.tile_ids[0].?;
        try testing.expectEqual(shared_id, rt.tile_ids[2].?);
        try testing.expectEqual(@as(usize, 0), unloads.items.len);
    }

    // Two uploads, two unloads — and the id two tiles share is released
    // ONCE. Unloading it per-tile would be a double free of a live GPU
    // texture (the leak labelle-gfx#347's revert proof surfaced).
    try testing.expectEqual(@as(usize, 2), unloads.items.len);
    try testing.expectEqual(@as(usize, 1), unloadCount(shared_id));
}

test "without gfx's re-arm seam a surface cycle leaves tilemap textures alone (#847)" {
    // This suite's renderer has no `invalidateTexture` /
    // `reuploadTextureFromMemory` — a pre-labelle-gfx#345 one. The runtime
    // must then neither invalidate nor unload anything (freeing through a
    // dead context is the #820 bug) nor re-upload: the pre-#847 contract.
    // The seam-carrying half is `tilemap_surface_test.zig`.
    defer clearLedger();
    try testing.expect(!ModernGame.TilemapRuntimeType.surface_reload_supported);

    var game = ModernGame.init(testing.allocator);
    defer game.deinit();
    try game.addEmbeddedTilemapAsset("level.tmx", shared_source_tmx);
    try game.addEmbeddedTilemapAsset("tree.png", fake_png);
    try game.addEmbeddedTilemapAsset("rock.png", fake_png);
    const e = game.createEntity();
    game.addTilemap(e, .{ .asset_name = "level.tmx" });
    const rt = game.tilemapRuntime(e) orelse return error.NoTilemapRuntime;

    game.surfaceLost();
    try testing.expect(!rt.surface_lost);
    game.surfaceRestored();
    try testing.expectEqual(@as(usize, 0), game.reloadTilemapTextures());
    try testing.expectEqual(@as(usize, 2), upload_count);
    try testing.expectEqual(@as(usize, 0), unloads.items.len);
}

test "a mixed map leaves the sheet tileset on the sheet path" {
    defer clearLedger();

    var game = ModernGame.init(testing.allocator);
    defer game.deinit();
    try game.addEmbeddedTilemapAsset("level.tmx", mixed_tmx);
    try game.addEmbeddedTilemapAsset("tiles.png", fake_png);
    try game.addEmbeddedTilemapAsset("tree.png", fake_png);
    try game.addEmbeddedTilemapAsset("rock.png", fake_png);

    const e = game.createEntity();
    game.addTilemap(e, .{ .asset_name = "level.tmx" });

    const rt = game.tilemapRuntime(e) orelse return error.NoTilemapRuntime;
    try testing.expectEqual(@as(usize, 2), rt.map.tilesets.len);

    // Tileset 0 is the sheet: one texture, resolved through `resolveFn`,
    // and no per-tile run at all (`tile_offsets[0] == tile_offsets[1]`).
    try testing.expectEqualStrings("tiles.png", rt.map.tilesets[0].image_source);
    try testing.expectEqual(@as(usize, 0), rt.map.tilesets[0].tile_images.len);
    try testing.expect(rt.tileset_ids[0] != null);
    try testing.expect(rt.tm.sheet[0] != null);
    try testing.expectEqual(rt.tileset_ids[0].?, rt.tm.sheet[0].?.id);

    // Tileset 1 is the collection: no sheet texture, two per-tile ones
    // (the self-closed `<tile id="1"/>` contributes no image).
    try testing.expect(rt.tileset_ids[1] == null);
    try testing.expect(rt.tm.sheet[1] == null);
    try testing.expectEqual(@as(usize, 2), rt.map.tilesets[1].tile_images.len);

    try testing.expectEqualSlices(usize, &.{ 0, 0, 2 }, rt.tile_offsets);
    try testing.expectEqual(@as(usize, 2), rt.tile_ids.len);
    for (rt.tile_ids) |id| try testing.expect(id != null);
    // The sheet id is never mistaken for a tile id.
    try testing.expect(rt.tile_ids[0].? != rt.tileset_ids[0].?);

    // One sheet + two props = three uploads, three unload-list entries.
    try testing.expectEqual(@as(usize, 3), upload_count);
    try testing.expectEqual(@as(usize, 3), rt.owned_ids.len);
}

test "an unregistered tile image degrades to an unresolved tile, not a failed map" {
    defer clearLedger();

    var game = ModernGame.init(testing.allocator);
    defer game.deinit();
    try game.addEmbeddedTilemapAsset("level.tmx", collection_tmx);
    // `sign.png` is deliberately absent from the catalog.
    try game.addEmbeddedTilemapAsset("tree.png", fake_png);
    try game.addEmbeddedTilemapAsset("rock.png", fake_png);

    const e = game.createEntity();
    game.addTilemap(e, .{ .asset_name = "level.tmx" });

    const rt = game.tilemapRuntime(e) orelse return error.NoTilemapRuntime;
    try testing.expectEqual(@as(usize, 2), upload_count);
    try testing.expect(rt.tile_ids[0] != null);
    try testing.expect(rt.tile_ids[1] != null);
    try testing.expect(rt.tile_ids[2] == null);
    try testing.expect(rt.tm.tiles[2] == null);
}

// ── The gate: an engine built against pre-#343 gfx ──────────────────────

test "gating: a pre-#343 gfx seam still has FULL tilemap support" {
    defer clearLedger();

    // The whole point of gating on `@hasField` rather than widening
    // `hasReflectableSeam`/`supported()`: older gfx must keep tilemaps, not
    // lose them. A `supported()`-level gate would make this `false` and
    // compile the entire feature to a `void` side table.
    try testing.expect(engine.tilemapSupported(FakeRender(false)));
    try testing.expect(LegacyGame.tilemap_supported);
    try testing.expect(LegacyGame.TilemapRuntimeType != void);

    var game = LegacyGame.init(testing.allocator);
    defer game.deinit();
    try game.addEmbeddedTilemapAsset("level.tmx", sheet_tmx);
    try game.addEmbeddedTilemapAsset("tiles.png", fake_png);

    const e = game.createEntity();
    game.addTilemap(e, .{ .asset_name = "level.tmx" });

    const rt = game.tilemapRuntime(e) orelse return error.NoTilemapRuntime;
    // The sheet path is byte-identical: one upload, one texture, and the
    // per-tile storage is not even allocated.
    try testing.expectEqual(@as(usize, 1), upload_count);
    try testing.expect(rt.tileset_ids[0] != null);
    try testing.expectEqual(@as(usize, 0), rt.tile_ids.len);
    try testing.expectEqual(@as(usize, 0), rt.tile_offsets.len);
    try testing.expectEqual(@as(usize, 1), rt.owned_ids.len);
    try testing.expect(rt.tm.sheet[0] != null);
}

test "gating: a pre-#343 gfx seam skips a collection tileset without failing the map" {
    defer clearLedger();

    var game = LegacyGame.init(testing.allocator);
    defer game.deinit();
    try game.addEmbeddedTilemapAsset("level.tmx", mixed_tmx);
    try game.addEmbeddedTilemapAsset("tiles.png", fake_png);
    try game.addEmbeddedTilemapAsset("tree.png", fake_png);

    const e = game.createEntity();
    game.addTilemap(e, .{ .asset_name = "level.tmx" });

    const rt = game.tilemapRuntime(e) orelse return error.NoTilemapRuntime;
    // The sheet tileset renders; the collection one does not (the documented
    // degrade on older gfx). Nothing crashes, nothing leaks.
    try testing.expectEqual(@as(usize, 2), rt.map.tilesets.len);
    try testing.expectEqual(@as(usize, 1), upload_count);
    try testing.expect(rt.tileset_ids[0] != null);
    try testing.expect(rt.tileset_ids[1] == null);
}

// ── The fixture parser's own guards (#843 review) ────────────────────────
//
// `parseTmx` is test scaffolding, but it is the scaffolding every case in
// this file is read through: a fixture it mis-parses silently would read as
// a bug in the code under test. These pin the three ways it used to accept
// a malformed fixture. All three are unreachable from the fixtures above —
// that is the point of writing them down.

test "a CSV short of width*height is rejected, not left undefined" {
    const Gfx = FakeGfx(true);
    // 3x2 = 6 gids declared, 4 supplied. `alloc` leaves the tail undefined,
    // so accepting this would place two garbage tiles.
    const tmx =
        \\<map width="3" height="2" tilewidth="16" tileheight="16">
        \\ <layer name="ground" width="3" height="2">
        \\  <data encoding="csv">
        \\1,1,1,1
        \\</data>
        \\ </layer>
        \\</map>
    ;
    try std.testing.expectError(error.InvalidTmx, parseTmx(Gfx, std.testing.allocator, tmx));
}

test "a CSV longer than width*height is rejected, not truncated" {
    const Gfx = FakeGfx(true);
    const tmx =
        \\<map width="3" height="2" tilewidth="16" tileheight="16">
        \\ <layer name="ground" width="3" height="2">
        \\  <data encoding="csv">
        \\1,1,1,1,1,1,1,1
        \\</data>
        \\ </layer>
        \\</map>
    ;
    try std.testing.expectError(error.InvalidTmx, parseTmx(Gfx, std.testing.allocator, tmx));
}

test "a data-less layer does not steal the next layer's gids" {
    const Gfx = FakeGfx(true);
    // `over` carries the only <data> in the buffer. Before the layer bound,
    // `ground` found it and both layers parsed as if they had gids.
    const tmx =
        \\<map width="2" height="1" tilewidth="16" tileheight="16">
        \\ <layer name="ground" width="2" height="1">
        \\ </layer>
        \\ <layer name="over" width="2" height="1">
        \\  <data encoding="csv">
        \\7,7
        \\</data>
        \\ </layer>
        \\</map>
    ;
    try std.testing.expectError(error.InvalidTmx, parseTmx(Gfx, std.testing.allocator, tmx));
}

test "a tileset parsed before a malformed layer does not leak" {
    const Gfx = FakeGfx(true);
    // The collection tileset's `tile_images` is allocated and handed to
    // `map` before the layer loop fails. testing.allocator is the assertion:
    // it reports any block the error path fails to release.
    const tmx =
        \\<map width="2" height="1" tilewidth="16" tileheight="16">
        \\ <tileset firstgid="1" name="props" tilewidth="16" tileheight="16" columns="0" tilecount="2">
        \\  <tile id="0">
        \\   <image source="a.png" width="16" height="16"/>
        \\  </tile>
        \\  <tile id="1">
        \\   <image source="b.png" width="16" height="16"/>
        \\  </tile>
        \\ </tileset>
        \\ <layer name="ground" width="2" height="1">
        \\ </layer>
        \\</map>
    ;
    try std.testing.expectError(error.InvalidTmx, parseTmx(Gfx, std.testing.allocator, tmx));
}

/// Parses and immediately tears down — the shape `checkAllAllocationFailures`
/// needs. Any block an error path fails to release shows up as a leak.
fn parseThenFree(allocator: std.mem.Allocator, tmx: []const u8) !void {
    var map = try parseTmx(FakeGfx(true), allocator, tmx);
    map.deinit();
}

test "parseTmx frees what it took at EVERY allocation failure point" {
    // Covers the whole ladder rather than one hand-picked failure: the
    // per-tile image list, its `toOwnedSlice`, the handover window before
    // `tilesets.append`, the layer gids, and both outer lists.
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        parseThenFree,
        .{collection_tmx},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        parseThenFree,
        .{mixed_tmx},
    );
}

/// A collection tileset whose images live in a DOTTED directory and whose
/// basenames carry no extension — the shape that made `fileTypeZ` return
/// the directory suffix instead of falling back. The sheet tileset shares
/// the same helper, so it pins both call sites at once.
const dotted_dir_tmx =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<map version="1.10" orientation="orthogonal" width="2" height="1" tilewidth="16" tileheight="16">
    \\ <tileset firstgid="1" name="terrain" tilewidth="16" tileheight="16" columns="4" tilecount="4">
    \\  <image source="packs.v2/terrain" width="64" height="16"/>
    \\ </tileset>
    \\ <tileset firstgid="5" name="props" tilewidth="16" tileheight="16" columns="0" tilecount="2">
    \\  <tile id="0">
    \\   <image source="props.v2/tree" width="16" height="16"/>
    \\  </tile>
    \\  <tile id="1">
    \\   <image source="props.v2/rock.PNG" width="16" height="16"/>
    \\  </tile>
    \\ </tileset>
    \\ <layer name="ground" width="2" height="1">
    \\  <data encoding="csv">
    \\1,5,
    \\</data>
    \\ </layer>
    \\</map>
;

test "a dot in the DIRECTORY is not an extension" {
    defer clearLedger();

    var game = ModernGame.init(testing.allocator);
    defer game.deinit();
    try game.addEmbeddedTilemapAsset("level.tmx", dotted_dir_tmx);
    try game.addEmbeddedTilemapAsset("packs.v2/terrain", fake_png);
    try game.addEmbeddedTilemapAsset("props.v2/tree", fake_png);
    try game.addEmbeddedTilemapAsset("props.v2/rock.PNG", fake_png);

    const e = game.createEntity();
    game.addTilemap(e, .{ .asset_name = "level.tmx" });
    const rt = game.tilemapRuntime(e) orelse return error.NoTilemapRuntime;

    // Every image uploaded — none rejected for an unusable file type.
    try testing.expectEqual(@as(usize, 3), upload_count);
    try testing.expect(rt.tileset_ids[0] != null);
    for (rt.tile_ids) |id| try testing.expect(id != null);

    // The sheet (pass 1) and the extensionless tile both fall back to
    // `.png`; the `.PNG` tile keeps its real extension, lowercased.
    // Taking the last dot of the whole path would have produced
    // `.v2/terrain` and `.v2/tree` here.
    try testing.expectEqual(@as(usize, 3), file_types.items.len);
    try testing.expectEqualStrings(".png", file_types.items[0]);
    try testing.expectEqualStrings(".png", file_types.items[1]);
    try testing.expectEqualStrings(".png", file_types.items[2]);
}
