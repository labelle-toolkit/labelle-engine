//! T3 — tilemap Z-interleave by named layer binding.
//!
//! Proves that individual `.tmx` layers render at their BOUND engine
//! layer's z, interleaved with the sprite layers (terrain below sprites,
//! canopy above), per active camera — against a renderer mock that mirrors
//! gfx v1.22.0's `renderWithLayerHook` seam: a per-active-camera, per-layer
//! loop that emits a sprite-pass sentinel for each engine layer and then
//! fires the engine's hook (inside the camera transform for world layers).
//!
//! The existing `test/tilemap_test.zig` mock has NO hook (`render()` only),
//! so it exercises the T2 whole-stack background fallback; this file's mock
//! adds the hook, driving the T3 interleave path. Together they cover both
//! branches of `loop_mixin.render`.

const std = @import("std");
const testing = std.testing;

const engine = @import("engine");
const core = @import("labelle-core");
const tilemap = @import("tilemap");

const GameConfig = engine.GameConfig;
const MockEcsBackend = engine.MockEcsBackend;
const StubInput = engine.StubInput;
const StubAudio = engine.StubAudio;
const StubVideo = engine.StubVideo;
const StubGui = engine.StubGui;
const StubLogSink = engine.StubLogSink;

const MockBackend = core.mock_backend.MockBackend;

// ── Fixtures ────────────────────────────────────────────────────────────

// A two-layer map: `terrain` (3×2, fully populated → 6 tiles) UNDER
// `canopy` (3×2, two non-zero gids → 2 tiles). Both layer names match a
// WORLD engine layer, so both interleave.
const terrain_canopy_tmx =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<map version="1.10" orientation="orthogonal" width="3" height="2" tilewidth="16" tileheight="16">
    \\ <tileset firstgid="1" name="test_tiles" tilewidth="16" tileheight="16" columns="4" tilecount="8">
    \\  <image source="tiles.png" width="64" height="32"/>
    \\ </tileset>
    \\ <layer name="terrain" width="3" height="2">
    \\  <data encoding="csv">
    \\1,2,3,
    \\4,5,6,
    \\</data>
    \\ </layer>
    \\ <layer name="canopy" width="3" height="2">
    \\  <data encoding="csv">
    \\0,7,0,
    \\0,8,0,
    \\</data>
    \\ </layer>
    \\</map>
;

// A single-layer map named `ground` — matches NO engine layer. With no
// explicit binding it is fully UNBOUND → the T2 background fallback.
const ground_tmx =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<map version="1.10" orientation="orthogonal" width="3" height="2" tilewidth="16" tileheight="16">
    \\ <tileset firstgid="1" name="test_tiles" tilewidth="16" tileheight="16" columns="4" tilecount="8">
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

// `terrain` (name-matches an engine layer → implicitly bound) + `foliage`
// (matches NO engine layer → unbound unless explicitly bound). Used for the
// partial-binding and explicit-override cases. foliage has 3 tiles.
const terrain_foliage_tmx =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<map version="1.10" orientation="orthogonal" width="3" height="2" tilewidth="16" tileheight="16">
    \\ <tileset firstgid="1" name="test_tiles" tilewidth="16" tileheight="16" columns="4" tilecount="8">
    \\  <image source="tiles.png" width="64" height="32"/>
    \\ </tileset>
    \\ <layer name="terrain" width="3" height="2">
    \\  <data encoding="csv">
    \\1,2,3,
    \\4,5,6,
    \\</data>
    \\ </layer>
    \\ <layer name="foliage" width="3" height="2">
    \\  <data encoding="csv">
    \\0,1,0,
    \\2,0,3,
    \\</data>
    \\ </layer>
    \\</map>
;

const fake_png = "\x89PNG\r\n\x1a\n fake tileset pixels";

/// Every tile draw uses the first minted texture handle (the single tileset).
const tileset_handle: u32 = 1;

// ── Hook-capable renderer mock ────────────────────────────────────────────

/// Engine layer stack (declaration order = z-order, low → high): terrain,
/// actors, canopy are WORLD layers; hud is a SCREEN layer. A sprite layer
/// (`actors`) sits between `terrain` and `canopy` so the test can prove a
/// bound terrain draws below it and a bound canopy above it.
const LayerEnum = enum {
    terrain,
    actors,
    canopy,
    hud,

    const Space = enum { world, screen };

    pub fn config(self: LayerEnum) struct { space: Space } {
        return switch (self) {
            .hud => .{ .space = .screen },
            else => .{ .space = .world },
        };
    }
};

const sentinel_base: u32 = 90000;
fn layerSentinel(comptime l: LayerEnum) u32 {
    return sentinel_base + @intFromEnum(l);
}

/// Minimal world camera mirroring gfx's `CameraWith` begin/end + getViewport
/// seam. `getViewport` returns the visible WORLD rect (Y-up), centered on the
/// camera position — the same shape gfx's `CameraWith.getViewport` returns —
/// so the engine's per-camera tilemap cull (#711) has a real viewport to read.
const MockCamera = struct {
    x: f32 = 0,
    y: f32 = 0,
    zoom: f32 = 1,
    /// World-space view extent (unzoomed). Defaults to an 800×600 window.
    view_w: f32 = 800,
    view_h: f32 = 600,

    pub fn setPosition(self: *MockCamera, x: f32, y: f32) void {
        self.x = x;
        self.y = y;
    }
    pub fn getViewport(self: *const MockCamera) struct { x: f32, y: f32, width: f32, height: f32 } {
        const w = self.view_w / self.zoom;
        const h = self.view_h / self.zoom;
        return .{ .x = self.x - w / 2, .y = self.y - h / 2, .width = w, .height = h };
    }
    pub fn begin(self: *const MockCamera) void {
        MockBackend.beginMode2D(.{ .target = .{ .x = self.x, .y = self.y }, .zoom = self.zoom });
    }
    pub fn end(_: *const MockCamera) void {
        MockBackend.endMode2D();
    }
};

/// Renderer mock: satisfies `core.RenderInterface`, exposes the gfx tilemap
/// seam AND gfx v1.22.0's per-layer render hook + a multi-camera loop.
const HookRender = struct {
    const Self = @This();

    /// The renderer's layer enum — the T3 interleave gate keys on this.
    pub const Layer = LayerEnum;

    pub const Sprite = struct {
        sprite_name: []const u8 = "",
        visible: bool = true,
        z_index: i16 = 0,
        layer: LayerEnum = .actors,
    };
    pub const Shape = struct {
        shape: union(enum) {
            rectangle: struct { width: f32 = 10, height: f32 = 10 },
            circle: struct { radius: f32 = 10 },
        } = .{ .rectangle = .{} },
        color: struct { r: u8 = 255, g: u8 = 255, b: u8 = 255, a: u8 = 255 } = .{},
        visible: bool = true,
        z_index: i16 = 0,
        layer: LayerEnum = .actors,
    };

    // ── gfx tilemap seam ──
    pub const TileMapRendererType = tilemap.TileMapRendererWith(MockBackend);
    pub const Inner = struct {
        pub const TextureInfo = struct { backend_texture: MockBackend.Texture };
    };

    // ── camera seam ──
    pub const CameraType = MockCamera;
    pub const CameraManagerType = struct {};

    inner: Inner = .{},
    alloc: std.mem.Allocator = undefined,
    textures: std.AutoHashMapUnmanaged(u32, MockBackend.Texture) = .empty,
    next_id: u32 = 1,
    render_count: usize = 0,
    cameras: [4]MockCamera = [_]MockCamera{.{}} ** 4,
    /// Number of active cameras the render loop iterates (split-screen).
    active_cameras: u8 = 1,
    screen_height: f32 = 600,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .alloc = allocator };
    }
    pub fn deinit(self: *Self) void {
        self.textures.deinit(self.alloc);
    }

    pub fn loadTextureFromMemory(self: *Self, file_type: [:0]const u8, data: []const u8) !u32 {
        _ = file_type;
        _ = data;
        const id = self.next_id;
        self.next_id += 1;
        try self.textures.put(self.alloc, id, .{ .id = id, .width = 64, .height = 32 });
        return id;
    }
    pub fn getTextureInfo(self: *const Self, id: u32) ?@TypeOf(self.inner).TextureInfo {
        const tex = self.textures.get(id) orelse return null;
        return .{ .backend_texture = tex };
    }
    pub fn unloadTexture(self: *Self, id: u32) void {
        _ = self.textures.remove(id);
    }

    // ── core.RenderInterface no-ops ──
    pub fn trackEntity(_: *Self, _: u32, _: core.render.VisualType) void {}
    pub fn untrackEntity(_: *Self, _: u32) void {}
    pub fn markPositionDirty(_: *Self, _: u32) void {}
    pub fn markPositionDirtyWithChildren(_: *Self, comptime _: type, _: anytype, _: u32) void {}
    pub fn updateHierarchyFlag(_: *Self, _: u32, _: bool) void {}
    pub fn markVisualDirty(_: *Self, _: u32) void {}
    pub fn sync(_: *Self, comptime _: type, _: anytype) void {}
    pub fn setScreenHeight(self: *Self, h: f32) void {
        self.screen_height = h;
    }
    pub fn getCamera(self: *Self) *MockCamera {
        return &self.cameras[0];
    }
    pub fn getCameraManager(self: *Self) *CameraManagerType {
        _ = self;
        return undefined;
    }
    pub fn renderGizmoDraws(_: *Self, _: []const core.gizmos.GizmoDraw) void {}
    pub fn hasEntity(_: *const Self, _: u32) bool {
        return false;
    }
    pub fn clear(self: *Self) void {
        self.render_count = 0;
    }

    fn emitSentinel(id: u32) void {
        MockBackend.drawTexturePro(
            .{ .id = id, .width = 1, .height = 1 },
            .{ .x = 0, .y = 0, .width = 1, .height = 1 },
            .{ .x = 0, .y = 0, .width = 1, .height = 1 },
            .{ .x = 0, .y = 0 },
            0,
            .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        );
    }

    /// gfx v1.24.0 dual-hook seam: per active camera, fire `on_before_layers`
    /// ONCE (inside the camera transform + scissor, before the layer stack —
    /// the pre-sprite BACKGROUND slot), then iterate the layer stack firing
    /// `on_after_layer` after each layer's sprite-pass sentinel.
    pub fn renderWithLayerHooks(
        self: *Self,
        comptime Ctx: type,
        ctx: Ctx,
        comptime on_before_layers: fn (Ctx, *const MockCamera) void,
        comptime on_after_layer: fn (Ctx, LayerEnum, *const MockCamera) void,
    ) void {
        self.render_count += 1;
        var ci: u8 = 0;
        while (ci < self.active_cameras) : (ci += 1) {
            const cam = &self.cameras[ci];
            // Pre-sprite background hook, inside the camera (world-space).
            cam.begin();
            on_before_layers(ctx, cam);
            cam.end();
            // Then the layer stack (camera re-entered per world layer).
            inline for (comptime std.enums.values(LayerEnum)) |l| {
                const world = comptime (l.config().space == .world);
                if (world) cam.begin();
                emitSentinel(layerSentinel(l)); // this layer's sprite pass
                on_after_layer(ctx, l, cam);
                if (world) cam.end();
            }
        }
    }

    /// gfx v1.22.0 single-hook seam — delegates with a no-op before-hook, so
    /// the mock still satisfies the older interface (behavior-identical).
    pub fn renderWithLayerHook(
        self: *Self,
        comptime Ctx: type,
        ctx: Ctx,
        comptime on_after_layer: fn (Ctx, LayerEnum, *const MockCamera) void,
    ) void {
        const noop_before = struct {
            fn f(_: Ctx, _: *const MockCamera) void {}
        }.f;
        self.renderWithLayerHooks(Ctx, ctx, noop_before, on_after_layer);
    }

    pub fn render(self: *Self) void {
        const noop = struct {
            fn f(_: void, _: LayerEnum, _: *const MockCamera) void {}
        }.f;
        self.renderWithLayerHook(void, {}, noop);
    }
};

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

fn InterleaveGame() type {
    return GameConfig(
        HookRender,
        MockEcsBackend(u32),
        StubInput,
        StubAudio,
        StubVideo,
        StubGui,
        void,
        StubLogSink,
        EmptyComponents,
        &.{},
        void,
    );
}

// ── Draw-record helpers ───────────────────────────────────────────────────

fn sentinelIndex(calls: anytype, id: u32) ?usize {
    for (calls, 0..) |c, i| {
        if (c.texture_id == id) return i;
    }
    return null;
}

/// Count tile draws (texture_id == the tileset handle) whose index falls in
/// the half-open range [lo, hi).
fn tileDrawsInRange(calls: anytype, lo: usize, hi: usize) usize {
    var n: usize = 0;
    for (calls, 0..) |c, i| {
        if (i < lo or i >= hi) continue;
        if (c.texture_id == tileset_handle) n += 1;
    }
    return n;
}

fn totalTileDraws(calls: anytype) usize {
    var n: usize = 0;
    for (calls) |c| {
        if (c.texture_id == tileset_handle) n += 1;
    }
    return n;
}

/// A renderer that DECLARES `renderWithLayerHook` AND the tilemap seam, but
/// whose `Layer` is `void` (a stub / non-standard renderer) — i.e. NOT a
/// genuine config-bearing enum. The T3 interleave gate must reject it (so the
/// engine never analyzes `stringToEnum(void, …)` / `void.config()`) and fall
/// back to the T2 whole-stack background path. Locks the gemini #711 fix.
const BadLayerRender = struct {
    const Self = @This();

    /// The offending decl: present (so the gate's `@hasDecl` step passes) but
    /// NOT an enum — the strengthened gate's `@typeInfo(Layer) == .@"enum"`
    /// check rejects it.
    pub const Layer = void;

    /// Existence is all the gate checks — signature is irrelevant here.
    pub fn renderWithLayerHook(_: *Self) void {}

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

    pub const TileMapRendererType = tilemap.TileMapRendererWith(MockBackend);
    pub const Inner = struct {
        pub const TextureInfo = struct { backend_texture: MockBackend.Texture };
    };

    inner: Inner = .{},
    alloc: std.mem.Allocator = undefined,
    textures: std.AutoHashMapUnmanaged(u32, MockBackend.Texture) = .empty,
    next_id: u32 = 1,
    screen_height: f32 = 600,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .alloc = allocator };
    }
    pub fn deinit(self: *Self) void {
        self.textures.deinit(self.alloc);
    }
    pub fn loadTextureFromMemory(self: *Self, file_type: [:0]const u8, data: []const u8) !u32 {
        _ = file_type;
        _ = data;
        const id = self.next_id;
        self.next_id += 1;
        try self.textures.put(self.alloc, id, .{ .id = id, .width = 64, .height = 32 });
        return id;
    }
    pub fn getTextureInfo(self: *const Self, id: u32) ?@TypeOf(self.inner).TextureInfo {
        const tex = self.textures.get(id) orelse return null;
        return .{ .backend_texture = tex };
    }
    pub fn unloadTexture(self: *Self, id: u32) void {
        _ = self.textures.remove(id);
    }
    pub fn trackEntity(_: *Self, _: u32, _: core.render.VisualType) void {}
    pub fn untrackEntity(_: *Self, _: u32) void {}
    pub fn markPositionDirty(_: *Self, _: u32) void {}
    pub fn markPositionDirtyWithChildren(_: *Self, comptime _: type, _: anytype, _: u32) void {}
    pub fn updateHierarchyFlag(_: *Self, _: u32, _: bool) void {}
    pub fn markVisualDirty(_: *Self, _: u32) void {}
    pub fn sync(_: *Self, comptime _: type, _: anytype) void {}
    pub fn setScreenHeight(self: *Self, h: f32) void {
        self.screen_height = h;
    }
    pub fn renderGizmoDraws(_: *Self, _: []const core.gizmos.GizmoDraw) void {}
    pub fn hasEntity(_: *const Self, _: u32) bool {
        return false;
    }
    pub fn clear(_: *Self) void {}
    pub fn render(_: *Self) void {}
};

fn BadLayerGame() type {
    return GameConfig(
        BadLayerRender,
        MockEcsBackend(u32),
        StubInput,
        StubAudio,
        StubVideo,
        StubGui,
        void,
        StubLogSink,
        EmptyComponents,
        &.{},
        void,
    );
}

// ── Tests ────────────────────────────────────────────────────────────────

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
    // camera, so the bound layers render twice — 16 tile draws. This is the
    // fix for #709 (T2's single background pass showed terrain only in the
    // primary viewport).
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

/// Build a `w×h` `.tmx` with the given `layer_names`, every cell set to gid 1
/// — a large map for the per-camera cull regressions. Caller frees.
fn buildFullTmx(alloc: std.mem.Allocator, w: u32, h: u32, layer_names: []const []const u8) ![]const u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(alloc);

    const header = try std.fmt.allocPrint(alloc,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<map version="1.10" orientation="orthogonal" width="{d}" height="{d}" tilewidth="16" tileheight="16">
        \\ <tileset firstgid="1" name="test_tiles" tilewidth="16" tileheight="16" columns="4" tilecount="8">
        \\  <image source="tiles.png" width="64" height="32"/>
        \\ </tileset>
        \\
    , .{ w, h });
    defer alloc.free(header);
    try list.appendSlice(alloc, header);

    for (layer_names) |name| {
        const lh = try std.fmt.allocPrint(alloc, " <layer name=\"{s}\" width=\"{d}\" height=\"{d}\">\n  <data encoding=\"csv\">\n", .{ name, w, h });
        defer alloc.free(lh);
        try list.appendSlice(alloc, lh);
        var row: u32 = 0;
        while (row < h) : (row += 1) {
            var col: u32 = 0;
            while (col < w) : (col += 1) try list.appendSlice(alloc, "1,");
            try list.append(alloc, '\n');
        }
        try list.appendSlice(alloc, "</data>\n </layer>\n");
    }
    try list.appendSlice(alloc, "</map>\n");
    return list.toOwnedSlice(alloc);
}

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

// ── Middle tier: renderer with only the OLD single hook (gfx 1.22–1.23) ──

/// A renderer that has `renderWithLayerHook` (interleave) + a valid config
/// `Layer`, but NOT the dual-hook `renderWithLayerHooks` — the gfx 1.22–1.23
/// shape. The gate must report interleave-supported but per-camera-background
/// UNsupported, so the engine keeps the single-primary background fallback.
const OldHookRender = struct {
    const Self = @This();

    pub const Layer = LayerEnum;
    pub const Sprite = HookRender.Sprite;
    pub const Shape = HookRender.Shape;
    pub const TileMapRendererType = tilemap.TileMapRendererWith(MockBackend);
    pub const Inner = struct {
        pub const TextureInfo = struct { backend_texture: MockBackend.Texture };
    };
    pub const CameraType = MockCamera;
    pub const CameraManagerType = struct {};

    inner: Inner = .{},
    alloc: std.mem.Allocator = undefined,
    textures: std.AutoHashMapUnmanaged(u32, MockBackend.Texture) = .empty,
    next_id: u32 = 1,
    camera: MockCamera = .{},
    screen_height: f32 = 600,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .alloc = allocator };
    }
    pub fn deinit(self: *Self) void {
        self.textures.deinit(self.alloc);
    }
    pub fn loadTextureFromMemory(self: *Self, _: [:0]const u8, _: []const u8) !u32 {
        const id = self.next_id;
        self.next_id += 1;
        try self.textures.put(self.alloc, id, .{ .id = id, .width = 64, .height = 32 });
        return id;
    }
    pub fn getTextureInfo(self: *const Self, id: u32) ?@TypeOf(self.inner).TextureInfo {
        const tex = self.textures.get(id) orelse return null;
        return .{ .backend_texture = tex };
    }
    pub fn unloadTexture(self: *Self, id: u32) void {
        _ = self.textures.remove(id);
    }
    pub fn trackEntity(_: *Self, _: u32, _: core.render.VisualType) void {}
    pub fn untrackEntity(_: *Self, _: u32) void {}
    pub fn markPositionDirty(_: *Self, _: u32) void {}
    pub fn markPositionDirtyWithChildren(_: *Self, comptime _: type, _: anytype, _: u32) void {}
    pub fn updateHierarchyFlag(_: *Self, _: u32, _: bool) void {}
    pub fn markVisualDirty(_: *Self, _: u32) void {}
    pub fn sync(_: *Self, comptime _: type, _: anytype) void {}
    pub fn setScreenHeight(self: *Self, h: f32) void {
        self.screen_height = h;
    }
    pub fn getCamera(self: *Self) *MockCamera {
        return &self.camera;
    }
    pub fn getCameraManager(self: *Self) *CameraManagerType {
        _ = self;
        return undefined;
    }
    pub fn renderGizmoDraws(_: *Self, _: []const core.gizmos.GizmoDraw) void {}
    pub fn hasEntity(_: *const Self, _: u32) bool {
        return false;
    }
    pub fn clear(_: *Self) void {}
    /// Only the SINGLE-hook seam — deliberately no `renderWithLayerHooks`.
    pub fn renderWithLayerHook(
        _: *Self,
        comptime Ctx: type,
        ctx: Ctx,
        comptime on_after_layer: fn (Ctx, LayerEnum, *const MockCamera) void,
    ) void {
        _ = ctx;
        _ = on_after_layer;
    }
    pub fn render(_: *Self) void {}
};

fn OldHookGame() type {
    return GameConfig(
        OldHookRender,
        MockEcsBackend(u32),
        StubInput,
        StubAudio,
        StubVideo,
        StubGui,
        void,
        StubLogSink,
        EmptyComponents,
        &.{},
        void,
    );
}

test "gate: a renderWithLayerHook-only renderer keeps interleave but NOT per-camera background" {
    const G = OldHookGame();
    try testing.expect(G.tilemap_supported);
    try testing.expect(G.tilemap_interleave_supported);
    // No `renderWithLayerHooks` → the per-camera background gate is OFF, so the
    // engine uses the single-primary `renderTilemapBackground` fallback.
    try testing.expect(!G.tilemap_percamera_background_supported);
}
