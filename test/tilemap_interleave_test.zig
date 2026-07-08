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

/// Minimal world camera mirroring gfx's `CameraWith` begin/end seam.
const MockCamera = struct {
    x: f32 = 0,
    y: f32 = 0,
    zoom: f32 = 1,

    pub fn setPosition(self: *MockCamera, x: f32, y: f32) void {
        self.x = x;
        self.y = y;
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

    /// gfx v1.22.0 seam: per active camera, iterate the layer stack; after
    /// each layer's sprite pass (a per-layer sentinel) fire `on_after_layer`
    /// — inside the camera transform for WORLD layers, outside for screen.
    pub fn renderWithLayerHook(
        self: *Self,
        comptime Ctx: type,
        ctx: Ctx,
        comptime on_after_layer: fn (Ctx, LayerEnum, *const MockCamera) void,
    ) void {
        self.render_count += 1;
        var ci: u8 = 0;
        while (ci < self.active_cameras) : (ci += 1) {
            const cam = &self.cameras[ci];
            inline for (comptime std.enums.values(LayerEnum)) |l| {
                const world = comptime (l.config().space == .world);
                if (world) cam.begin();
                emitSentinel(layerSentinel(l)); // this layer's sprite pass
                on_after_layer(ctx, l, cam);
                if (world) cam.end();
            }
        }
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

// ── Tests ────────────────────────────────────────────────────────────────

test "the hook-capable renderer enables the T3 interleave path" {
    try testing.expect(InterleaveGame().tilemap_supported);
    try testing.expect(InterleaveGame().tilemap_interleave_supported);
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
