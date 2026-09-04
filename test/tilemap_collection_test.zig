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
//! is what `FakeGfx` below is. `FakeGfx(true)` is the post-#343 shape,
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
    \\ <tileset firstgid="9" name="props" tilewidth="16" tileheight="16" columns="0" tilecount="2">
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

/// Frees the ledger AND resets it for the next test. Registered as the
/// FIRST `defer` in each test so it runs LAST — after `game.deinit()`,
/// whose unloads are exactly what the teardown test reads.
fn clearLedger() void {
    unloads.deinit(testing.allocator);
    unloads = .empty;
    upload_count = 0;
}

fn unloadCount(id: u32) usize {
    var n: usize = 0;
    for (unloads.items) |u| {
        if (u == id) n += 1;
    }
    return n;
}

// ── A stand-in for gfx's tilemap seam ───────────────────────────────────

/// gfx's tilemap types, in both the pre- and post-labelle-gfx#343 shapes.
/// `with_collection = true` adds `Tileset.tile_images` and the optional
/// `TextureResolver.resolveTileFn`; `false` is byte-for-byte the shape gfx
/// v1.31.0 ships, which is what the engine is pinned against today.
fn FakeGfx(comptime with_collection: bool) type {
    return struct {
        const Gfx = @This();

        /// Backend texture handle. `id` mirrors the catalog texture id the
        /// engine minted, so a test can tie a resolved tile straight back
        /// to the upload it came from.
        pub const Texture = struct { id: u32 };

        pub const TileImage = struct {
            local_id: u32,
            source: []const u8,
            width: u32,
            height: u32,
        };

        pub const Tileset = if (with_collection) struct {
            firstgid: u32 = 0,
            name: []const u8 = "",
            tile_width: u32 = 0,
            tile_height: u32 = 0,
            columns: u32 = 0,
            tile_count: u32 = 0,
            image_source: []const u8 = "",
            image_width: u32 = 0,
            image_height: u32 = 0,
            tile_images: []const TileImage = &.{},
        } else struct {
            firstgid: u32 = 0,
            name: []const u8 = "",
            tile_width: u32 = 0,
            tile_height: u32 = 0,
            columns: u32 = 0,
            tile_count: u32 = 0,
            image_source: []const u8 = "",
            image_width: u32 = 0,
            image_height: u32 = 0,
        };

        pub const TileLayer = struct {
            name: []const u8 = "",
            width: u32 = 0,
            height: u32 = 0,
            data: []u32 = &.{},

            pub fn getTile(self: *const TileLayer, x: u32, y: u32) u32 {
                return self.data[y * self.width + x];
            }
        };

        /// Stands in for gfx's `TileMap` decoder. `loadFromMemoryWithBasePath`
        /// runs a deliberately small TMX scan — enough to bind an `<image>`
        /// to its enclosing `<tile>`, which is the only decode detail this
        /// suite depends on. The real parse is gfx's, and is covered by
        /// labelle-gfx#347's own tests.
        pub const TileMap = struct {
            allocator: std.mem.Allocator,
            width: u32 = 0,
            height: u32 = 0,
            tile_width: u32 = 0,
            tile_height: u32 = 0,
            tilesets: []Tileset = &.{},
            tile_layers: []TileLayer = &.{},

            pub fn loadFromMemoryWithBasePath(
                allocator: std.mem.Allocator,
                bytes: []const u8,
                base_path: []const u8,
            ) !TileMap {
                _ = base_path;
                return parseTmx(Gfx, allocator, bytes);
            }

            pub fn deinit(self: *TileMap) void {
                for (self.tilesets) |ts| {
                    if (comptime with_collection) self.allocator.free(ts.tile_images);
                }
                self.allocator.free(self.tilesets);
                for (self.tile_layers) |l| self.allocator.free(l.data);
                self.allocator.free(self.tile_layers);
            }

            pub fn getPixelHeight(self: *const TileMap) u32 {
                return self.height * self.tile_height;
            }
        };

        /// Stands in for `TileMapRendererWith(Backend)`. Resolution is
        /// EAGER (inside `initWithOptions`), matching gfx, and every answer
        /// is recorded so a test can assert what each tile got.
        pub const TileMapRenderer = struct {
            pub const TextureResolver = if (with_collection) struct {
                context: ?*anyopaque = null,
                resolveFn: *const fn (context: ?*anyopaque, tileset_index: usize, tileset: *const Tileset) ?Texture,
                resolveTileFn: ?*const fn (
                    context: ?*anyopaque,
                    tileset_index: usize,
                    tileset: *const Tileset,
                    image_index: usize,
                    image: *const TileImage,
                ) ?Texture = null,
            } else struct {
                context: ?*anyopaque = null,
                resolveFn: *const fn (context: ?*anyopaque, tileset_index: usize, tileset: *const Tileset) ?Texture,
            };

            pub const InitOptions = struct {
                resolver: ?TextureResolver = null,
                load_unresolved_from_filesystem: bool = true,
            };

            allocator: std.mem.Allocator,
            map: *const TileMap,
            /// One entry per tileset: what `resolveFn` answered (the sheet).
            sheet: []?Texture,
            /// Flat, one entry per per-tile image, in the same
            /// `(tileset, image)` order the engine lays out `tile_ids`.
            tiles: []?Texture,
            /// Set when the caller supplied a per-tile resolver at all.
            had_tile_resolver: bool = false,
            draws: usize = 0,

            pub fn initWithOptions(
                allocator: std.mem.Allocator,
                map: *const TileMap,
                options: InitOptions,
            ) !TileMapRenderer {
                const sheet = try allocator.alloc(?Texture, map.tilesets.len);
                errdefer allocator.free(sheet);
                var total: usize = 0;
                if (comptime with_collection) {
                    for (map.tilesets) |*ts| total += ts.tile_images.len;
                }
                const tiles = try allocator.alloc(?Texture, total);
                errdefer allocator.free(tiles);

                var self = TileMapRenderer{
                    .allocator = allocator,
                    .map = map,
                    .sheet = sheet,
                    .tiles = tiles,
                };

                var cursor: usize = 0;
                for (map.tilesets, 0..) |*ts, i| {
                    sheet[i] = if (options.resolver) |r| r.resolveFn(r.context, i, ts) else null;
                    if (comptime with_collection) {
                        for (ts.tile_images, 0..) |*img, j| {
                            defer cursor += 1;
                            tiles[cursor] = null;
                            const r = options.resolver orelse continue;
                            const f = r.resolveTileFn orelse continue;
                            self.had_tile_resolver = true;
                            tiles[cursor] = f(r.context, i, ts, j, img);
                        }
                    }
                }
                return self;
            }

            pub fn deinit(self: *TileMapRenderer) void {
                self.allocator.free(self.sheet);
                self.allocator.free(self.tiles);
            }

            pub fn drawAllLayers(self: *TileMapRenderer, _: f32, _: f32, _: anytype) void {
                self.draws += 1;
            }

            pub fn drawLayerDirect(self: *TileMapRenderer, _: *const TileLayer, _: f32, _: f32, _: anytype) void {
                self.draws += 1;
            }
        };
    };
}

// ── Minimal TMX scan (see `TileMap.loadFromMemoryWithBasePath`) ──────────

fn attrStr(el: []const u8, name: []const u8) ?[]const u8 {
    var buf: [32]u8 = undefined;
    // Leading space so `width="…"` never matches inside `tilewidth="…"`.
    const needle = std.fmt.bufPrint(&buf, " {s}=\"", .{name}) catch return null;
    const at = std.mem.indexOf(u8, el, needle) orelse return null;
    const start = at + needle.len;
    const end = std.mem.indexOfScalarPos(u8, el, start, '"') orelse return null;
    return el[start..end];
}

fn attrU32(el: []const u8, name: []const u8) u32 {
    const s = attrStr(el, name) orelse return 0;
    return std.fmt.parseInt(u32, s, 10) catch 0;
}

/// The span of the element starting at `open` (a `<`), i.e. everything up
/// to and including its `>`.
fn elementHeader(bytes: []const u8, open: usize) []const u8 {
    const close = std.mem.indexOfScalarPos(u8, bytes, open, '>') orelse bytes.len - 1;
    return bytes[open .. close + 1];
}

fn parseTmx(comptime Gfx: type, allocator: std.mem.Allocator, bytes: []const u8) !Gfx.TileMap {
    const with_collection = @hasField(Gfx.Tileset, "tile_images");

    var map = Gfx.TileMap{ .allocator = allocator };
    const map_open = std.mem.indexOf(u8, bytes, "<map ") orelse return error.InvalidTmx;
    const map_el = elementHeader(bytes, map_open);
    map.width = attrU32(map_el, "width");
    map.height = attrU32(map_el, "height");
    map.tile_width = attrU32(map_el, "tilewidth");
    map.tile_height = attrU32(map_el, "tileheight");

    var tilesets: std.ArrayList(Gfx.Tileset) = .empty;
    errdefer tilesets.deinit(allocator);

    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, pos, "<tileset ")) |open| {
        const el = elementHeader(bytes, open);
        var ts = Gfx.Tileset{
            .firstgid = attrU32(el, "firstgid"),
            .name = attrStr(el, "name") orelse "",
            .tile_width = attrU32(el, "tilewidth"),
            .tile_height = attrU32(el, "tileheight"),
            .columns = attrU32(el, "columns"),
            .tile_count = attrU32(el, "tilecount"),
        };
        const body_start = open + el.len;
        const body_end = std.mem.indexOfPos(u8, bytes, body_start, "</tileset>") orelse bytes.len;
        const body = bytes[body_start..body_end];
        pos = body_end;

        // Track the enclosing `<tile>` so an `<image>` binds to it — the
        // one decode detail this suite leans on. A self-closed `<tile/>`
        // opens nothing.
        var images: std.ArrayList(Gfx.TileImage) = .empty;
        errdefer images.deinit(allocator);
        var current_tile: ?u32 = null;
        var i: usize = 0;
        while (i < body.len) {
            const next = std.mem.indexOfScalarPos(u8, body, i, '<') orelse break;
            const tag = elementHeader(body, next);
            i = next + tag.len;
            if (std.mem.startsWith(u8, tag, "<tile ") or std.mem.startsWith(u8, tag, "<tile>")) {
                current_tile = if (std.mem.endsWith(u8, tag, "/>")) null else attrU32(tag, "id");
            } else if (std.mem.startsWith(u8, tag, "</tile>")) {
                current_tile = null;
            } else if (std.mem.startsWith(u8, tag, "<image ")) {
                const source = attrStr(tag, "source") orelse "";
                if (current_tile) |local_id| {
                    if (comptime with_collection) {
                        try images.append(allocator, .{
                            .local_id = local_id,
                            .source = source,
                            .width = attrU32(tag, "width"),
                            .height = attrU32(tag, "height"),
                        });
                    }
                } else {
                    ts.image_source = source;
                    ts.image_width = attrU32(tag, "width");
                    ts.image_height = attrU32(tag, "height");
                }
            }
        }
        if (comptime with_collection) {
            ts.tile_images = try images.toOwnedSlice(allocator);
        } else {
            images.deinit(allocator);
        }
        try tilesets.append(allocator, ts);
    }
    map.tilesets = try tilesets.toOwnedSlice(allocator);

    var layers: std.ArrayList(Gfx.TileLayer) = .empty;
    errdefer layers.deinit(allocator);
    pos = 0;
    while (std.mem.indexOfPos(u8, bytes, pos, "<layer ")) |open| {
        const el = elementHeader(bytes, open);
        var layer = Gfx.TileLayer{
            .name = attrStr(el, "name") orelse "",
            .width = attrU32(el, "width"),
            .height = attrU32(el, "height"),
        };
        const data_open = std.mem.indexOfPos(u8, bytes, open, "<data ") orelse return error.InvalidTmx;
        const data_el = elementHeader(bytes, data_open);
        const csv_start = data_open + data_el.len;
        const csv_end = std.mem.indexOfPos(u8, bytes, csv_start, "</data>") orelse return error.InvalidTmx;
        var gids = try allocator.alloc(u32, layer.width * layer.height);
        errdefer allocator.free(gids);
        var n: usize = 0;
        var it = std.mem.tokenizeAny(u8, bytes[csv_start..csv_end], ",\n\r \t");
        while (it.next()) |tok| {
            if (n >= gids.len) break;
            gids[n] = std.fmt.parseInt(u32, tok, 10) catch 0;
            n += 1;
        }
        layer.data = gids;
        try layers.append(allocator, layer);
        pos = csv_end;
    }
    map.tile_layers = try layers.toOwnedSlice(allocator);
    return map;
}

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
            _ = file_type;
            _ = data;
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
