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
//! texture path sprites use) and are therefore owned by the renderer's
//! shared texture registry, NOT by the tilemap renderer — the resolver
//! seam hands them over as unowned. They are freed when the renderer is
//! deinited (scene teardown / shutdown), so `Runtime.deinit` does not
//! unload them (see `TileMapRenderer.TextureEntry.owned`).

const std = @import("std");

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
        tileset_ids: []?TextureId,
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
        };

        fn resolveTexture(context: ?*anyopaque, index: usize, tileset: *const Tileset) ?Texture {
            _ = tileset;
            const ctx: *const ResolverCtx = @ptrCast(@alignCast(context.?));
            if (index >= ctx.ids.len) return null;
            const id = ctx.ids[index] orelse return null;
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
            // base_path "" — embedded env: the resolver supplies textures,
            // and the filesystem fallback is disabled below.
            var map = try TileMap.loadFromMemoryWithBasePath(allocator, tmx_bytes, "");
            errdefer map.deinit();

            const ids = try allocator.alloc(?TextureId, map.tilesets.len);
            errdefer allocator.free(ids);
            for (ids) |*slot| slot.* = null;

            for (map.tilesets, 0..) |*tileset, i| {
                if (tileset.image_source.len == 0) continue;
                const bytes = images.get(tileset.image_source) orelse continue;
                const ft = try fileTypeZ(allocator, tileset.image_source);
                defer allocator.free(ft);
                // A missing/undecodable tileset image degrades to "this
                // tileset draws nothing" rather than failing the whole map.
                ids[i] = renderer.loadTextureFromMemory(ft, bytes) catch null;
            }

            self.* = .{
                .allocator = allocator,
                .renderer = renderer,
                .map = map,
                .tm = undefined,
                .tileset_ids = ids,
                .resolver_ctx = undefined,
            };

            // Point the resolver at the heap-stable field (not a stack local),
            // so the context outlives `initInPlace` for any resolution timing.
            self.resolver_ctx = .{ .renderer = renderer, .ids = self.tileset_ids };
            self.tm = try TmRenderer.initWithOptions(allocator, &self.map, .{
                .resolver = Resolver{ .context = &self.resolver_ctx, .resolveFn = resolveTexture },
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
            // Dedup so a tileset id that (in a future engine that dedups
            // uploads by content) backs two tilesets is never double-unloaded.
            for (self.tileset_ids, 0..) |maybe_id, i| {
                const id = maybe_id orelse continue;
                var already = false;
                for (self.tileset_ids[0..i]) |prev| {
                    if (prev) |p| {
                        if (p == id) {
                            already = true;
                            break;
                        }
                    }
                }
                if (!already) self.renderer.unloadTexture(id);
            }
            self.map.deinit();
            self.allocator.free(self.tileset_ids);
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

/// Allocator-owned, null-terminated lowercase-ish file-type token derived
/// from an `image_source` extension (e.g. `"tiles.png"` → `"png"`).
/// Defaults to `"png"` when there is no extension. Caller frees.
fn fileTypeZ(allocator: std.mem.Allocator, image_source: []const u8) ![:0]const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, image_source, '.');
    const ext = if (dot) |d| image_source[d + 1 ..] else "";
    const chosen = if (ext.len == 0) "png" else ext;
    const out = try allocator.dupeZ(u8, chosen);
    // Normalise to lowercase so a `.PNG` tileset resolves the same decoder
    // as `.png` (the image loaders dispatch on a lowercase file type).
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}
