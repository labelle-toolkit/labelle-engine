//! Shared test support: a stand-in for labelle-gfx's tilemap seam
//! (`TileMap` decoder + `TileMapRendererWith(Backend)`), in both the
//! pre- and post-labelle-gfx#343 shapes, plus the minimal TMX scan behind
//! it. Path-imported by `tilemap_collection_test.zig` (#841) and
//! `tilemap_surface_test.zig` (#847); no `test` blocks here. See the
//! collection suite's header for why a stand-in rather than the pinned gfx.

const std = @import("std");

// ── A stand-in for gfx's tilemap seam ───────────────────────────────────

/// gfx's tilemap types, in both the pre- and post-labelle-gfx#343 shapes.
/// `with_collection = true` adds `Tileset.tile_images` and the optional
/// `TextureResolver.resolveTileFn`; `false` is byte-for-byte the shape gfx
/// v1.31.0 ships, which is what the engine is pinned against today.
pub fn FakeGfx(comptime with_collection: bool) type {
    return struct {
        const Gfx = @This();

        /// Backend texture handle. `id` mirrors the catalog texture id the
        /// engine minted, so a test can tie a resolved tile straight back
        /// to the upload it came from.
        /// `gen` is the upload generation the fake renderer stamps on each
        /// (re)upload of that id — 0 for suites that never re-upload — so a
        /// surface-restore test can tell a FRESH backend texture from the
        /// dead one it replaced under the same id (#847).
        pub const Texture = struct { id: u32, gen: u32 = 0 };

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

pub fn parseTmx(comptime Gfx: type, allocator: std.mem.Allocator, bytes: []const u8) !Gfx.TileMap {
    const with_collection = @hasField(Gfx.Tileset, "tile_images");

    var map = Gfx.TileMap{ .allocator = allocator };
    // Covers everything ownership has moved INTO `map` (its `deinit` frees
    // the nested `tile_images` and `data` too). `tilesets`/`tile_layers`
    // default to `&.{}`, so this is a no-op until the first handover.
    errdefer map.deinit();
    const map_open = std.mem.indexOf(u8, bytes, "<map ") orelse return error.InvalidTmx;
    const map_el = elementHeader(bytes, map_open);
    map.width = attrU32(map_el, "width");
    map.height = attrU32(map_el, "height");
    map.tile_width = attrU32(map_el, "tilewidth");
    map.tile_height = attrU32(map_el, "tileheight");

    var tilesets: std.ArrayList(Gfx.Tileset) = .empty;
    // Each appended tileset may own a `tile_images` allocation, which the
    // list's own `deinit` does not reach. After `toOwnedSlice` the list is
    // empty and this loop is a no-op — `map.deinit` covers them from there.
    errdefer {
        for (tilesets.items) |ts| {
            if (comptime with_collection) allocator.free(ts.tile_images);
        }
        tilesets.deinit(allocator);
    }

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
        // `toOwnedSlice` emptied `images`, so its errdefer above no longer
        // covers these bytes and the list errdefer cannot yet — `ts` is not
        // appended. This window is exactly one fallible call wide.
        errdefer if (comptime with_collection) allocator.free(ts.tile_images);
        try tilesets.append(allocator, ts);
    }
    map.tilesets = try tilesets.toOwnedSlice(allocator);

    var layers: std.ArrayList(Gfx.TileLayer) = .empty;
    // Same shape as `tilesets`: every appended layer owns its `data`.
    errdefer {
        for (layers.items) |l| allocator.free(l.data);
        layers.deinit(allocator);
    }
    pos = 0;
    while (std.mem.indexOfPos(u8, bytes, pos, "<layer ")) |open| {
        const el = elementHeader(bytes, open);
        var layer = Gfx.TileLayer{
            .name = attrStr(el, "name") orelse "",
            .width = attrU32(el, "width"),
            .height = attrU32(el, "height"),
        };
        // Both markers must fall inside THIS layer. Searching the whole
        // buffer would hand a data-less layer the next layer's gids and
        // parse "successfully" — a fixture bug that would read as a code
        // bug in whatever test used it.
        const layer_end = std.mem.indexOfPos(u8, bytes, open, "</layer>") orelse bytes.len;
        const data_open = std.mem.indexOfPos(u8, bytes, open, "<data ") orelse return error.InvalidTmx;
        if (data_open >= layer_end) return error.InvalidTmx;
        const data_el = elementHeader(bytes, data_open);
        const csv_start = data_open + data_el.len;
        const csv_end = std.mem.indexOfPos(u8, bytes, csv_start, "</data>") orelse return error.InvalidTmx;
        if (csv_end >= layer_end) return error.InvalidTmx;
        var gids = try allocator.alloc(u32, layer.width * layer.height);
        errdefer allocator.free(gids);
        var n: usize = 0;
        var it = std.mem.tokenizeAny(u8, bytes[csv_start..csv_end], ",\n\r \t");
        while (it.next()) |tok| {
            // Surplus gids are rejected rather than dropped, and a short
            // CSV is rejected below: `alloc` leaves the tail UNDEFINED, so
            // a miscounted fixture would otherwise place garbage tiles.
            if (n >= gids.len) return error.InvalidTmx;
            gids[n] = std.fmt.parseInt(u32, tok, 10) catch 0;
            n += 1;
        }
        if (n != gids.len) return error.InvalidTmx;
        layer.data = gids;
        try layers.append(allocator, layer);
        pos = csv_end;
    }
    map.tile_layers = try layers.toOwnedSlice(allocator);
    return map;
}
