//! Per-entity tilemap draw-pass runtime (T2 Phase 2).
//!
//! The engine is renderer-agnostic — it never imports labelle-gfx. It
//! reaches gfx's tilemap types the same way it reaches `Sprite`/`Shape`
//! and the `drawMesh` seam: through the renderer plugin (`RenderImpl`).
//! This module centralises ALL the reflection needed to name gfx's
//! `TileMap` decoder + `TileMapRenderer` (`RenderImpl.TileMapRendererType`,
//! shipped by gfx 1.21.0), so the rest of the engine stays gfx-free.
//!
//! `supported(RenderImpl)` gates the whole feature: a renderer that does
//! not expose the tilemap seam (e.g. a bare test stub) compiles to a void
//! side table and no-op mixin methods — purely additive, zero cost.
//!
//! Ownership: the decoded `TileMap` and the `TileMapRenderer` live inside
//! `Runtime`, which `Game` heap-allocates (stable address — the renderer
//! keeps a `*const TileMap` into `Runtime.map`). Tileset textures are
//! uploaded through `RenderImpl.loadTextureFromMemory` (the SAME backend
//! texture path sprites use) and handed to gfx through the resolver seam as
//! UNOWNED, so `TileMapRenderer` never frees them (see
//! `TileMapRenderer.TextureEntry.owned`). The uploader owns them instead:
//! `Runtime.deinit` unloads every id in `owned_ids`, which holds each
//! uploaded texture exactly once.
//!
//! Two tileset layouts are served. A **sheet** is one image sliced by a
//! uniform grid — one texture per tileset, in `tileset_ids`. A **collection
//! of images** (`columns="0"`) has one `<image>` per `<tile>` and no sheet —
//! one texture per per-tile `source`, in the flat `tile_ids`. The second is
//! gated at comptime on gfx carrying labelle-gfx#343; see
//! `collection_supported` in `Runtime`.

const std = @import("std");

const TileLayerSize = @import("tilemap.zig").TileLayerSize;

/// True when `RenderImpl` exposes the gfx 1.21.0 tilemap seam: the
/// per-backend `TileMapRenderer` type plus the shared texture path the
/// resolver bridges through. `GfxRendererWith` satisfies all of it.
///
/// Two gates, both required:
///   1. NAME presence — the four decls that spell the seam exist.
///   2. CONCRETE reflectability — the exact shapes `Runtime` derives its
///      types from are present AND non-generic (`hasReflectableSeam`).
///
/// Gate 2 exists because `@hasDecl` alone is a trap: gfx 1.21.0's
/// `GfxRendererWith.getTextureInfo` returns `?@TypeOf(self.inner).TextureInfo`,
/// whose dependence on the `self` PARAMETER makes the wrapper a GENERIC
/// function — so `@typeInfo(...).@"fn".return_type` is `null`. A `@hasDecl`
/// pass therefore let `Runtime` be instantiated even though reflecting that
/// return type fails to COMPILE (`error: unable to unwrap null`), which broke
/// every headless/null-backend consumer on gfx 1.21.0. `Runtime` no longer
/// reflects that generic wrapper (it keys `Texture` off the concrete resolver
/// seam instead), and `supported()` verifies the concrete seam up front so
/// the two can never disagree. A renderer without a reflectable seam (a bare
/// test stub, a malformed backend) reports `false` → the feature compiles to
/// a `void` side-table no-op instead of failing the whole build.
pub fn supported(comptime RenderImpl: type) bool {
    return @hasDecl(RenderImpl, "TileMapRendererType") and
        @hasDecl(RenderImpl, "loadTextureFromMemory") and
        @hasDecl(RenderImpl, "getTextureInfo") and
        // `unloadTexture` is the counterpart to `loadTextureFromMemory` —
        // the runtime OWNS the tileset textures it uploads (gfx receives
        // them as unowned via the resolver) and must release them on
        // teardown (F1). `GfxRendererWith` declares all four.
        @hasDecl(RenderImpl, "unloadTexture") and
        hasReflectableSeam(RenderImpl);
}

/// True when every type `Runtime` derives from `RenderImpl` is present and
/// CONCRETELY reflectable. Each step is guarded by a tag/field check before
/// it reflects, so a malformed seam returns `false` rather than triggering a
/// compile error here. Callers must have already confirmed the four seam
/// decls exist (see `supported`).
fn hasReflectableSeam(comptime RenderImpl: type) bool {
    if (!@hasDecl(RenderImpl, "TileMapRendererType")) return false;
    const TmRenderer = RenderImpl.TileMapRendererType;
    if (@typeInfo(TmRenderer) != .@"struct") return false;

    // `Runtime` derives `TileMap` (and `Tileset`) from these concrete fields.
    if (!@hasField(TmRenderer, "map")) return false;
    if (@typeInfo(@FieldType(TmRenderer, "map")) != .pointer) return false;
    const TileMap = @typeInfo(@FieldType(TmRenderer, "map")).pointer.child;
    if (@typeInfo(TileMap) != .@"struct" or !@hasField(TileMap, "tilesets")) return false;
    if (@typeInfo(@FieldType(TileMap, "tilesets")) != .pointer) return false;

    // The backend texture handed to the tilemap renderer — derived from the
    // CONCRETE resolver fn-pointer, never the generic `getTextureInfo` wrapper.
    if (!@hasDecl(TmRenderer, "TextureResolver")) return false;
    const Resolver = TmRenderer.TextureResolver;
    if (@typeInfo(Resolver) != .@"struct" or !@hasField(Resolver, "resolveFn")) return false;
    const ResolveFnPtr = @FieldType(Resolver, "resolveFn");
    if (@typeInfo(ResolveFnPtr) != .pointer) return false;
    const ResolveFn = @typeInfo(ResolveFnPtr).pointer.child;
    if (@typeInfo(ResolveFn) != .@"fn") return false;
    const resolve_ret = @typeInfo(ResolveFn).@"fn".return_type orelse return false;
    if (@typeInfo(resolve_ret) != .optional) return false;

    // The shared upload path must expose a concrete (non-generic) error-union
    // return so `Runtime` can name the texture-id handle it threads around.
    const LoadInfo = @typeInfo(@TypeOf(RenderImpl.loadTextureFromMemory));
    if (LoadInfo != .@"fn") return false;
    const load_ret = LoadInfo.@"fn".return_type orelse return false;
    if (@typeInfo(load_ret) != .error_union) return false;

    return true;
}

/// Supplies raw image bytes for a tileset's `image_source` name. The
/// engine backs this with `Game`'s embedded tilemap-asset registry so the
/// runtime stays decoupled from `Game`.
pub const ImageProvider = struct {
    context: ?*anyopaque = null,
    getFn: *const fn (context: ?*anyopaque, name: []const u8) ?[]const u8,

    fn get(self: ImageProvider, name: []const u8) ?[]const u8 {
        return self.getFn(self.context, name);
    }
};

/// The per-entity tilemap runtime for a given renderer plugin. Only
/// instantiate when `supported(RenderImpl)` is true.
pub fn Runtime(comptime RenderImpl: type) type {
    const TmRenderer = RenderImpl.TileMapRendererType;

    // `TileMapRenderer.map` is `*const TileMap` — derive the gfx `TileMap`
    // decoder type without naming gfx directly.
    const TileMapPtr = @FieldType(TmRenderer, "map");
    const TileMap = @typeInfo(TileMapPtr).pointer.child;

    // `Tileset` = element of `TileMap.tilesets` (a `[]Tileset`).
    const TilesetsField = @FieldType(TileMap, "tilesets");
    const Tileset = @typeInfo(TilesetsField).pointer.child;

    // Texture-id handle returned by `loadTextureFromMemory` (threaded back
    // into `getTextureInfo` — the engine never needs to name it).
    const LoadRet = @typeInfo(@TypeOf(RenderImpl.loadTextureFromMemory)).@"fn".return_type.?;
    const TextureId = @typeInfo(LoadRet).error_union.payload;

    const Resolver = TmRenderer.TextureResolver;

    // Backend texture type the resolver must hand to the tilemap renderer.
    // Derived from the CONCRETE `TextureResolver.resolveFn` signature
    // (`fn (…) ?Texture`) — NOT from `RenderImpl.getTextureInfo`'s return
    // type. gfx 1.21.0's `GfxRendererWith.getTextureInfo` returns
    // `?@TypeOf(self.inner).TextureInfo`, whose dependence on the `self`
    // parameter makes the wrapper a GENERIC function, so its `return_type`
    // reflects as `null` and `.?` would fail to compile on every backend
    // (headless/null-backend regression fixed in v1.75.1). The resolver
    // carries the same `Texture` concretely; we call `getTextureInfo` only
    // at RUNTIME below, where its generic return type resolves fine.
    const ResolveFnPtr = @FieldType(Resolver, "resolveFn");
    const ResolveRet = @typeInfo(@typeInfo(ResolveFnPtr).pointer.child).@"fn".return_type.?;
    const Texture = @typeInfo(ResolveRet).optional.child;

    // ── Collection-of-images tilesets (#841 / labelle-gfx#343) ──────────
    //
    // A Tiled "collection of images" tileset has NO sheet: each `<tile>`
    // carries its own `<image>`, so one tileset needs N textures rather
    // than one. gfx grows `Tileset.tile_images` (a `[]const TileImage`)
    // and an OPTIONAL `TextureResolver.resolveTileFn` for it.
    //
    // The gate is a pair of `@hasField` checks on the two shapes this
    // module actually reflects — deliberately NOT a new clause in
    // `hasReflectableSeam` (and therefore not in `supported()`). An engine
    // built against an OLDER gfx must keep its tilemaps: widening
    // `supported()` would make every such build report the whole tilemap
    // feature as absent (`void` side table, no `.tmx` renders at all)
    // rather than merely losing collection support, which is the strictly
    // additive degrade this is meant to be. Older gfx therefore still
    // compiles, still draws sheet tilesets, and skips collection ones
    // exactly as it does today.
    const collection_supported = @hasField(Tileset, "tile_images") and
        @hasField(Resolver, "resolveTileFn");

    // Element of `Tileset.tile_images` — gfx's `TileImage` (`local_id`,
    // `source`, `width`, `height`). `void` when gfx predates #343; the
    // branch is comptime-dead there and never analyzed.
    const TileImage = if (collection_supported)
        @typeInfo(@FieldType(Tileset, "tile_images")).pointer.child
    else
        void;

    return struct {
        const Self = @This();

        pub const MapType = TileMap;

        allocator: std.mem.Allocator,
        renderer: *RenderImpl,
        /// Decoded map — MUST stay at a stable address; `tm` holds a
        /// `*const TileMap` into it. `Game` heap-allocates the `Runtime`.
        map: TileMap,
        /// The gfx tilemap draw-pass renderer, bound to this backend.
        tm: TmRenderer,
        /// Per-tileset catalog texture id (null = image unresolved →
        /// that tileset draws nothing). Read by the resolver trampoline.
        /// SHEET tilesets only — a collection tileset has no sheet and its
        /// slot stays null.
        tileset_ids: []?TextureId,
        /// Per-TILE catalog texture ids for collection-of-images tilesets
        /// (#841), FLAT and index-addressed: tileset `i`'s image `j` lives
        /// at `tile_ids[tile_offsets[i] + j]`. Flat because gfx hands the
        /// resolver `(tileset_index, image_index)` directly, so one
        /// allocation covers the whole map and lookup is two loads — no
        /// slice-of-slices, no hash map on the draw path. Empty ONLY on a gfx
        /// predating labelle-gfx#343; otherwise its length is the map's
        /// total per-tile image count, which is 0 for a sheet-only map.
        tile_ids: []?TextureId,
        /// Start of each tileset's run inside `tile_ids`; length
        /// `tilesets.len + 1`, so tileset `i` owns
        /// `tile_ids[tile_offsets[i]..tile_offsets[i + 1]]`. Empty only on a
        /// pre-#343 gfx; on any newer gfx it is allocated whether or not
        /// the map holds a collection tileset, and a sheet-only map simply
        /// leaves every run empty (all offsets 0).
        tile_offsets: []usize,
        /// Every texture id this runtime UPLOADED, each exactly once — the
        /// unload list. Distinct from `tileset_ids`/`tile_ids`, which are
        /// lookup tables and may repeat an id (several tiles sharing one
        /// `source` share one texture). Unloading a shared id twice is a
        /// use-after-free, so ownership is tracked here and nowhere else,
        /// which also makes `deinit` O(n) instead of the O(n²) dedup scan
        /// it replaces.
        owned_ids: []TextureId,
        /// Resolver context, stored inline so its address is heap-stable
        /// (matches the `Game`-heap-allocated `Runtime`). gfx resolves
        /// textures eagerly inside `initWithOptions` today — but keeping
        /// the context alongside the renderer keeps the code correct even
        /// if gfx ever moves to lazy (draw-time) resolution, instead of
        /// silently depending on that timing across the repo boundary.
        resolver_ctx: ResolverCtx,

        const ResolverCtx = struct {
            renderer: *RenderImpl,
            ids: []const ?TextureId,
            tile_ids: []const ?TextureId = &.{},
            tile_offsets: []const usize = &.{},
        };

        fn resolveTexture(context: ?*anyopaque, index: usize, tileset: *const Tileset) ?Texture {
            _ = tileset;
            const ctx: *const ResolverCtx = @ptrCast(@alignCast(context.?));
            if (index >= ctx.ids.len) return null;
            const id = ctx.ids[index] orelse return null;
            const info = ctx.renderer.getTextureInfo(id) orelse return null;
            return info.backend_texture;
        }

        /// Per-tile counterpart of `resolveTexture` (#841): answers gfx's
        /// `TextureResolver.resolveTileFn` for a collection-of-images
        /// tileset. Only ever installed when `collection_supported`.
        ///
        /// Like `resolveTexture` this calls `getTextureInfo` at RUNTIME
        /// only — the wrapper's return type references its `self`
        /// parameter, which makes it a GENERIC function whose
        /// `return_type` reflects as `null`; reflecting it is the
        /// v1.75.1 null-backend regression (see `hasReflectableSeam`).
        /// The trampoline exists precisely so the id → `Texture`
        /// conversion stays behind a call rather than a type derivation.
        fn resolveTileTexture(
            context: ?*anyopaque,
            tileset_index: usize,
            tileset: *const Tileset,
            image_index: usize,
            image: *const TileImage,
        ) ?Texture {
            _ = tileset;
            _ = image;
            const ctx: *const ResolverCtx = @ptrCast(@alignCast(context.?));
            // Two shapes reach here with nothing to resolve, and one check
            // covers both: on a pre-#343 gfx `tile_offsets` is empty, so the
            // length test rejects; on a newer gfx with a sheet-only map it is
            // allocated but every run is empty, so `end - base` is 0 and the
            // image test rejects.
            if (tileset_index + 1 >= ctx.tile_offsets.len) return null;
            const base = ctx.tile_offsets[tileset_index];
            const end = ctx.tile_offsets[tileset_index + 1];
            if (image_index >= end - base) return null;
            const id = ctx.tile_ids[base + image_index] orelse return null;
            const info = ctx.renderer.getTextureInfo(id) orelse return null;
            return info.backend_texture;
        }

        /// Decode `tmx_bytes`, upload each tileset image through the
        /// shared texture path, and bind the draw-pass renderer. `self`
        /// MUST already sit at its final (heap-stable) address.
        pub fn initInPlace(
            self: *Self,
            allocator: std.mem.Allocator,
            renderer: *RenderImpl,
            tmx_bytes: []const u8,
            images: ImageProvider,
        ) !void {
            // base_path "" — embedded env: there is no directory to resolve
            // against, so gfx forces its filesystem fallback off and a
            // `<tileset source="…tsx"/>` can only come from the resolver.
            //
            // The SAME provider serves both: the engine keeps one registry
            // (`embedded_tilemap_sources`) holding the `.tmx`, each tileset
            // image, and each external `.tsx`, and gfx keys the `.tsx` off the
            // `source` attribute exactly as written — which is the key
            // labelle-assembler registers it under. The two callbacks have an
            // identical signature, so the resolver is the same function.
            //
            // Gated on the decl: gfx before labelle-gfx#336 has no
            // options-taking entry point, and an engine built against it must
            // still compile (external tilesets then keep failing with
            // `error.ExternalTilesetUnsupported`, exactly as before).
            var map = if (comptime @hasDecl(TileMap, "loadFromMemoryWithOptions")) blk: {
                const LoadOptions = @typeInfo(@TypeOf(TileMap.loadFromMemoryWithOptions)).@"fn".params[3].type.?;
                const TsxResolver = @typeInfo(@FieldType(LoadOptions, "tsx_resolver")).optional.child;
                break :blk try TileMap.loadFromMemoryWithOptions(allocator, tmx_bytes, "", LoadOptions{
                    .tsx_resolver = TsxResolver{
                        .context = images.context,
                        .resolveFn = images.getFn,
                    },
                });
            } else try TileMap.loadFromMemoryWithBasePath(allocator, tmx_bytes, "");
            errdefer map.deinit();

            const ids = try allocator.alloc(?TextureId, map.tilesets.len);
            errdefer allocator.free(ids);
            for (ids) |*slot| slot.* = null;

            // Total per-tile images across the map — 0 for a sheet-only map
            // (and on gfx without #343), which keeps every allocation and
            // loop below a no-op on the sheet path.
            const tile_total: usize = if (comptime collection_supported) blk: {
                var n: usize = 0;
                for (map.tilesets) |*tileset| n += tileset.tile_images.len;
                break :blk n;
            } else 0;

            // The unload list (see `owned_ids`). Capacity is reserved up
            // front — one sheet per tileset plus every per-tile image — so
            // no append inside the upload loops can fail after a texture is
            // already on the GPU.
            var owned: std.ArrayList(TextureId) = .empty;
            errdefer owned.deinit(allocator);
            try owned.ensureTotalCapacity(allocator, map.tilesets.len + tile_total);
            // Every texture uploaded so far is released if a LATER step
            // fails; without this the map's textures would outlive the
            // half-built runtime that owns them.
            errdefer for (owned.items) |id| renderer.unloadTexture(id);

            // ── Pass 1: one sheet texture per tileset (unchanged) ───────
            for (map.tilesets, 0..) |*tileset, i| {
                if (tileset.image_source.len == 0) continue;
                const bytes = images.get(tileset.image_source) orelse continue;
                const ft = try fileTypeZ(allocator, tileset.image_source);
                defer allocator.free(ft);
                // A missing/undecodable tileset image degrades to "this
                // tileset draws nothing" rather than failing the whole map.
                // But say so: a silent `catch null` made a decode FAILURE
                // indistinguishable from a tileset that legitimately draws
                // nothing, which is precisely what hid the dotless
                // `file_type` bug for as long as it did (#835).
                ids[i] = renderer.loadTextureFromMemory(ft, bytes) catch |err| blk: {
                    std.log.warn(
                        "tilemap: tileset image '{s}' ({s}, {d} bytes) failed to decode: {s} — this tileset will draw nothing",
                        .{ tileset.image_source, ft, bytes.len, @errorName(err) },
                    );
                    break :blk null;
                };
                if (ids[i]) |id| owned.appendAssumeCapacity(id);
            }

            // ── Pass 2: one texture per per-tile image (#841) ───────────
            //
            // Deduplicated by `source`, and that is CORRECTNESS, not an
            // optimisation: gfx's `recordTexture` mints a fresh key on
            // every call and caches nothing, so N tiles naming one image
            // would become N GPU textures — and the ids would then all be
            // distinct, so `deinit` would unload the same image N times.
            // The map is init-time scaffolding only; the draw path reads
            // the flat `tile_ids` array.
            var tile_ids: []?TextureId = &.{};
            var tile_offsets: []usize = &.{};
            if (comptime collection_supported) {
                tile_offsets = try allocator.alloc(usize, map.tilesets.len + 1);
                errdefer allocator.free(tile_offsets);
                tile_ids = try allocator.alloc(?TextureId, tile_total);
                errdefer allocator.free(tile_ids);

                var by_source = std.StringHashMap(TextureId).init(allocator);
                defer by_source.deinit();
                try by_source.ensureTotalCapacity(@intCast(tile_total));

                var cursor: usize = 0;
                for (map.tilesets, 0..) |*tileset, i| {
                    tile_offsets[i] = cursor;
                    for (tileset.tile_images) |*image| {
                        defer cursor += 1;
                        tile_ids[cursor] = null;
                        if (image.source.len == 0) continue;
                        if (by_source.get(image.source)) |shared| {
                            tile_ids[cursor] = shared;
                            continue;
                        }
                        const bytes = images.get(image.source) orelse continue;
                        const ft = try fileTypeZ(allocator, image.source);
                        defer allocator.free(ft);
                        // Same degrade-don't-fail contract as a sheet: an
                        // unresolvable tile image draws nothing, the rest
                        // of the map still renders.
                        const id = renderer.loadTextureFromMemory(ft, bytes) catch |err| {
                            std.log.warn(
                                "tilemap: tile image '{s}' ({s}, {d} bytes) failed to decode: {s} — this tile will draw nothing",
                                .{ image.source, ft, bytes.len, @errorName(err) },
                            );
                            continue;
                        };
                        tile_ids[cursor] = id;
                        owned.appendAssumeCapacity(id);
                        // Keyed by the `source` slice, which the decoded
                        // `TileMap` owns and outlives this init.
                        by_source.putAssumeCapacity(image.source, id);
                    }
                }
                tile_offsets[map.tilesets.len] = cursor;
            }
            errdefer allocator.free(tile_offsets);
            errdefer allocator.free(tile_ids);

            // `toOwnedSlice` empties `owned`, so the unload errdefer above
            // no longer covers these ids — carry the same guarantee over.
            const owned_ids = try owned.toOwnedSlice(allocator);
            errdefer {
                for (owned_ids) |id| renderer.unloadTexture(id);
                allocator.free(owned_ids);
            }

            self.* = .{
                .allocator = allocator,
                .renderer = renderer,
                .map = map,
                .tm = undefined,
                .tileset_ids = ids,
                .tile_ids = tile_ids,
                .tile_offsets = tile_offsets,
                .owned_ids = owned_ids,
                .resolver_ctx = undefined,
            };

            // Point the resolver at the heap-stable field (not a stack local),
            // so the context outlives `initInPlace` for any resolution timing.
            self.resolver_ctx = .{
                .renderer = renderer,
                .ids = self.tileset_ids,
                .tile_ids = self.tile_ids,
                .tile_offsets = self.tile_offsets,
            };
            var resolver = Resolver{ .context = &self.resolver_ctx, .resolveFn = resolveTexture };
            // Additive: `resolveTileFn` does not exist on gfx before #343,
            // and a resolver that leaves it null behaves exactly as today.
            if (comptime collection_supported) resolver.resolveTileFn = resolveTileTexture;
            self.tm = try TmRenderer.initWithOptions(allocator, &self.map, .{
                .resolver = resolver,
                // Embedded env: never touch the filesystem for unresolved
                // tilesets — the resolver is the only texture source.
                .load_unresolved_from_filesystem = false,
            });
        }

        pub fn deinit(self: *Self) void {
            self.tm.deinit();
            // Release the tileset textures this runtime uploaded (F1). gfx
            // received them through the resolver as UNOWNED, so `tm.deinit`
            // does NOT free them — the runtime that uploaded them owns them.
            //
            // `owned_ids` already holds each uploaded id EXACTLY ONCE (init
            // dedups per-tile images by `source`), so this is a flat O(n)
            // walk. It replaces an O(n²) dedup scan over `tileset_ids` that
            // was dead while every tileset uploaded its own sheet — and that
            // would now be quadratic in the number of per-tile textures a
            // collection map can hold.
            for (self.owned_ids) |id| self.renderer.unloadTexture(id);
            self.map.deinit();
            self.allocator.free(self.tileset_ids);
            self.allocator.free(self.tile_ids);
            self.allocator.free(self.tile_offsets);
            self.allocator.free(self.owned_ids);
        }

        /// The map's height in pixels (`tile_height * rows`). Used by the
        /// engine's render pass to apply the project Y-axis flip to the
        /// map's world offset so a tilemap and a sprite at the same
        /// `Position.y` align (F3).
        pub fn pixelHeight(self: *const Self) f32 {
            return @floatFromInt(self.map.getPixelHeight());
        }

        /// The post-sprite draw pass for this entity. `offset_x/offset_y`
        /// is the entity's world `Position`; `camera_x/camera_y` are the
        /// world coords of the view's top-left (0,0 when the caller runs
        /// the pass in screen space, T2's default). Draws every visible
        /// tile layer in document order.
        pub fn draw(
            self: *Self,
            camera_x: f32,
            camera_y: f32,
            offset_x: f32,
            offset_y: f32,
            view_width: ?f32,
            view_height: ?f32,
        ) void {
            self.tm.drawAllLayers(camera_x, camera_y, .{
                .offset_x = offset_x,
                .offset_y = offset_y,
                .view_width = view_width,
                .view_height = view_height,
            });
        }

        /// Number of `.tmx` tile layers in this map (T3 Z-interleave). The
        /// engine iterates these to resolve each layer's engine-layer
        /// binding without naming gfx's `TileLayer` type directly.
        pub fn layerCount(self: *const Self) usize {
            return self.map.tile_layers.len;
        }

        /// Name of the i-th `.tmx` tile layer (document order) — the key the
        /// engine matches against a `LayerEnum` `@tagName` / explicit
        /// `layer_bindings` to decide where the layer draws (T3).
        pub fn layerName(self: *const Self, i: usize) []const u8 {
            return self.map.tile_layers[i].name;
        }

        // ── Runtime tile mutation (#825) ────────────────────────────

        /// Grid size (in TILES) of the i-th `.tmx` tile layer. The bound a
        /// caller needs before pushing a whole grid through
        /// `setLayerTiles` (which requires an exact `width * height`
        /// slice).
        pub fn layerSize(self: *const Self, i: usize) TileLayerSize {
            const layer = &self.map.tile_layers[i];
            return .{ .width = layer.width, .height = layer.height };
        }

        /// Overwrite ONE tile of the i-th tile layer in the decoded map.
        /// Returns `false` (writing nothing) when `x`/`y` fall outside the
        /// layer's grid.
        ///
        /// `gid` is the RAW TMX global tile id: `0` clears the cell, and
        /// the three high flip bits (`TileFlags.*`, `0xE0000000`) are
        /// preserved verbatim — the draw pass decodes them itself.
        ///
        /// Safe to call at any time outside a draw: gfx's tilemap renderer
        /// is IMMEDIATE-mode (it reads `TileLayer.data` afresh every
        /// `drawLayerDirect`), so there is no cached geometry to invalidate
        /// and no dirty flag to raise — the next frame shows the new tile.
        ///
        /// **Not persisted.** The save/load contract stores only the
        /// component's `asset_name` and rehydrates by RE-DECODING the
        /// `.tmx`, so every runtime mutation is lost across a save/load or
        /// a scene reload. See `src/tilemap.zig`.
        pub fn setTile(self: *Self, i: usize, x: u32, y: u32, gid: u32) bool {
            const layer = &self.map.tile_layers[i];
            if (x >= layer.width or y >= layer.height) return false;
            const idx = @as(usize, y) * @as(usize, layer.width) + @as(usize, x);
            if (idx >= layer.data.len) return false; // defensive: malformed decode
            layer.data[idx] = gid;
            return true;
        }

        /// Replace the ENTIRE tile grid of the i-th tile layer in one call —
        /// the bulk form a procedural generator uses to push a freshly
        /// computed grid without a `.tmx` round-trip. `gids` is row-major
        /// (`y * width + x`), raw TMX gids, and MUST be exactly
        /// `width * height` long; a mismatched length writes nothing and
        /// returns `false`.
        ///
        /// Same immediacy and same non-persistence as `setTile`.
        ///
        /// ALIASING IS ALLOWED. `Game.tilemapRuntime` is public, so a
        /// caller can reach `layer.data` and hand that very slice (or a
        /// same-length view into the same decode allocation) straight
        /// back — a natural "read the grid, tweak it in place, push it
        /// back" loop. `@memcpy` forbids that (safety builds panic,
        /// optimized builds are UB), so the copy runs in whichever
        /// direction tolerates an overlap, and an identical slice is a
        /// no-op that still reports success.
        pub fn setLayerTiles(self: *Self, i: usize, gids: []const u32) bool {
            const layer = &self.map.tile_layers[i];
            if (gids.len != layer.data.len) return false;
            if (layer.data.ptr == gids.ptr) return true; // self-assignment
            if (@intFromPtr(layer.data.ptr) < @intFromPtr(gids.ptr)) {
                std.mem.copyForwards(u32, layer.data, gids);
            } else {
                std.mem.copyBackwards(u32, layer.data, gids);
            }
            return true;
        }

        /// Draw a SINGLE `.tmx` tile layer by document index (T3
        /// Z-interleave), at the entity's world offset. Counterpart to
        /// `draw` (whole stack) — used from the engine's per-layer render
        /// hook so a bound `.tmx` layer draws at its engine layer's z,
        /// interleaved with the sprite layers. `camera_x/camera_y` are 0
        /// when the caller runs inside a backend camera transform (the
        /// interleave path always does).
        ///
        /// `view_start_x/view_start_y` (gfx ≥1.23.0) set the CULL origin
        /// separately from the dest offset (`camera_x/y`). On the interleave
        /// path `camera_x/y = 0` keeps dest world-space for the camera matrix,
        /// while the caller passes the ACTIVE camera's visible world rect here
        /// so a panned camera on a large map culls the tiles it actually sees
        /// (codex #711 P1). `null` = today's behavior (cull origin = dest
        /// offset). `view_width/height` size the cull rect.
        pub fn drawLayerAt(
            self: *Self,
            i: usize,
            camera_x: f32,
            camera_y: f32,
            offset_x: f32,
            offset_y: f32,
            view_start_x: ?f32,
            view_start_y: ?f32,
            view_width: ?f32,
            view_height: ?f32,
        ) void {
            self.tm.drawLayerDirect(&self.map.tile_layers[i], camera_x, camera_y, .{
                .offset_x = offset_x,
                .offset_y = offset_y,
                .view_start_x = view_start_x,
                .view_start_y = view_start_y,
                .view_width = view_width,
                .view_height = view_height,
            });
        }
    };
}

/// Allocator-owned, null-terminated lowercase file-type token derived from
/// an `image_source` extension, KEEPING its leading dot (e.g.
/// `"tiles.png"` → `".png"`). Defaults to `".png"` when there is no
/// extension. Caller frees.
///
/// The dot is load-bearing (#835). labelle-raylib's `decodeImage` forwards
/// this token straight to raylib's `LoadImageFromMemory`, which dispatches
/// through a chain of `strcmp(fileType, ".png")` — WITH the dot. A dotless
/// `"png"` matches no arm, falls out to raylib's "Data format not supported"
/// warning and returns an EMPTY image, which the caller's `catch null`
/// then degrades to a silently blank tileset. It stayed invisible because
/// `decodeImage` returns from its pre-baked `LRGBA` fast path before
/// `file_type` is ever read (so a baked project never reaches the strcmp),
/// and labelle-sokol discards the argument entirely (stb_image sniffs the
/// magic bytes) — leaving raylib + an UNBAKED tileset image as the only
/// combination that bit.
///
/// Dotted is the IMAGE spelling across the toolkit: it is what
/// labelle-assembler emits for atlases (`loadAtlasFromMemory(…, ".png")`)
/// and what `registerImageFromMemory` documents. It is deliberately NOT the
/// sound/font spelling — `labelle-audio/src/decode.zig` dispatches on
/// `std.mem.eql(u8, file_type, "wav")`, dotless, and the assembler emits an
/// `extWithoutDot` token for those two kinds. The kinds genuinely differ;
/// do not "unify" them.
fn fileTypeZ(allocator: std.mem.Allocator, image_source: []const u8) ![:0]const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, image_source, '.');
    // Slice FROM the dot, not past it, so the token keeps its leading dot.
    // A bare trailing dot (`"tiles."`) carries no extension, so it falls
    // back the same way a dotless source does.
    const ext = if (dot) |d| image_source[d..] else "";
    const chosen = if (ext.len <= 1) ".png" else ext;
    const out = try allocator.dupeZ(u8, chosen);
    // Normalise to lowercase so a `.PNG` tileset resolves the same decoder
    // as `.png` (the image loaders dispatch on a lowercase file type).
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}
