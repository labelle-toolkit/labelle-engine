//! T2 Phase 2 — engine `Tilemap` component end-to-end.
//!
//! Proves the whole path against the ACTUALLY-shipped gfx 1.21.0 tilemap
//! API (the engine module itself takes no gfx dependency — see
//! `src/tilemap_runtime.zig`):
//!   1. `addTilemap` decodes an embedded `.tmx` through gfx's
//!      `TileMap.loadFromMemoryWithBasePath` into a per-entity runtime.
//!   2. The tilemap draws as a POST-SPRITE pass at the entity's world
//!      `Position` offset — asserted through gfx's real
//!      `TileMapRendererWith(MockBackend)` recording draw calls, and
//!      ordered strictly after the entity (sprite) render pass.
//!   3. Save persists ONLY `asset_name`; load rehydrates the runtime.
//!   4. The editor scene digest reports the tilemap entity.
//!
//! The renderer here is a hand-rolled mock satisfying `core.RenderInterface`
//! that additionally exposes the gfx tilemap seam (`TileMapRendererType`
//! bound to `core.MockBackend`, plus `loadTextureFromMemory`/`getTextureInfo`
//! standing in for the shared sprite texture path). This mirrors how the
//! production `GfxRendererWith` exposes those exact decls — INCLUDING that
//! `getTextureInfo`'s return type references the `self` parameter
//! (`?@TypeOf(self.inner).TextureInfo`), which makes the wrapper a GENERIC
//! function. That generic seam is exactly what regressed on gfx 1.21.0 +
//! the null backend (engine v1.75.1): `supported()` must still report the
//! backend as supported, and `Runtime` must still compile, by keying its
//! `Texture` type off the CONCRETE resolver seam rather than reflecting the
//! generic wrapper's return type.

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
const editor_api = engine.editor_api;

const MockBackend = core.mock_backend.MockBackend;

// A minimal, valid Tiled map: 3×2 tiles of 16px, one embedded tileset
// (`tiles.png`), one fully-populated CSV tile layer (6 non-zero gids).
const minimal_tmx =
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

// Stand-in tileset image bytes. The mock renderer's `loadTextureFromMemory`
// never decodes them — it just mints a handle — so any non-empty blob works.
const fake_png = "\x89PNG\r\n\x1a\n fake tileset pixels";

/// The sprite pass emits one draw with this sentinel texture id, so the
/// test can prove tilemap tiles are drawn strictly BEFORE it (the terrain
/// is the background layer, under the gameplay sprites).
const sprite_sentinel_id: u32 = 90001;

/// A minimal world camera exposing the `begin()/end()` seam the engine
/// wraps the tilemap pass in — mirrors gfx's `CameraWith`. `begin()`
/// records a backend camera pass whose target reflects the camera
/// position, so a test can prove the tilemap pass runs UNDER the camera
/// transform and that a camera pan shifts that transform.
const MockCamera = struct {
    x: f32 = 0,
    y: f32 = 0,
    zoom: f32 = 1,

    pub fn setPosition(self: *MockCamera, x: f32, y: f32) void {
        self.x = x;
        self.y = y;
    }
    pub fn begin(self: *const MockCamera) void {
        MockBackend.beginMode2D(.{
            .target = .{ .x = self.x, .y = self.y },
            .zoom = self.zoom,
        });
    }
    pub fn end(_: *const MockCamera) void {
        MockBackend.endMode2D();
    }
};

/// Renderer mock: satisfies `core.RenderInterface` and exposes the gfx
/// 1.21.0 tilemap seam. `render()` emits a sentinel sprite-pass draw.
const MockRender = struct {
    const Self = @This();

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

    // ── gfx 1.21.0 tilemap seam (as GfxRendererWith exposes it) ──
    pub const TileMapRendererType = tilemap.TileMapRendererWith(MockBackend);
    /// Stand-in for `GfxRendererWith`'s wrapped `RetainedEngine` (`self.inner`).
    /// `getTextureInfo` names its `TextureInfo` off THIS, exactly as the
    /// production wrapper does — which is what makes the wrapper generic.
    pub const Inner = struct {
        pub const TextureInfo = struct { backend_texture: MockBackend.Texture };
    };

    // ── camera seam (as GfxRendererWith exposes it) ──
    // Present so the engine wraps the tilemap pass in the world camera
    // transform (`camera_capable`), exactly as it does for `GfxRendererWith`.
    // `CameraManagerType` is declared alongside `CameraType` because the
    // engine's `has_camera` gate derives BOTH from the renderer.
    pub const CameraType = MockCamera;
    pub const CameraManagerType = struct {};

    inner: Inner = .{},
    alloc: std.mem.Allocator = undefined,
    textures: std.AutoHashMapUnmanaged(u32, MockBackend.Texture) = .empty,
    next_id: u32 = 1,
    render_count: usize = 0,
    camera: MockCamera = .{},
    /// Logical screen height sprites (and the tilemap y-flip) flip against —
    /// mirrors `GfxRendererWith.screen_height` (set via `setScreenHeight`).
    screen_height: f32 = 600,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .alloc = allocator };
    }
    pub fn deinit(self: *Self) void {
        self.textures.deinit(self.alloc);
    }

    // Upload path shared with sprites — mints a backend texture + handle.
    pub fn loadTextureFromMemory(self: *Self, file_type: [:0]const u8, data: []const u8) !u32 {
        _ = file_type;
        _ = data;
        const id = self.next_id;
        self.next_id += 1;
        try self.textures.put(self.alloc, id, .{ .id = id, .width = 64, .height = 32 });
        return id;
    }
    // Return type references `self` (`?@TypeOf(self.inner).TextureInfo`) →
    // GENERIC function, byte-for-byte the shape of gfx `GfxRendererWith`. Its
    // `@"fn".return_type` reflects as `null`; the fix must NOT reflect it.
    pub fn getTextureInfo(self: *const Self, id: u32) ?@TypeOf(self.inner).TextureInfo {
        const tex = self.textures.get(id) orelse return null;
        return .{ .backend_texture = tex };
    }
    /// Release counterpart — the runtime unloads the tileset textures it
    /// uploaded (F1). Idempotent: a stale id is a safe no-op.
    pub fn unloadTexture(self: *Self, id: u32) void {
        _ = self.textures.remove(id);
    }

    // ── core.RenderInterface no-ops (mirror StubRender) ──
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
    pub fn clear(self: *Self) void {
        self.render_count = 0;
    }

    /// The entity (sprite) pass. Emits one sentinel draw so a following
    /// tilemap pass is provably post-sprite.
    pub fn render(self: *Self) void {
        self.render_count += 1;
        MockBackend.drawTexturePro(
            .{ .id = sprite_sentinel_id, .width = 1, .height = 1 },
            .{ .x = 0, .y = 0, .width = 1, .height = 1 },
            .{ .x = 0, .y = 0, .width = 1, .height = 1 },
            .{ .x = 0, .y = 0 },
            0,
            .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        );
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

fn TilemapGame() type {
    return GameConfig(
        MockRender,
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

fn registerFixture(game: anytype) !void {
    try game.addEmbeddedTilemapAsset("level.tmx", minimal_tmx);
    try game.addEmbeddedTilemapAsset("tiles.png", fake_png);
}

test "the renderer plugin exposes the gfx tilemap seam" {
    try testing.expect(TilemapGame().tilemap_supported);
}

test "regression: a GENERIC getTextureInfo seam is still supported (null-backend / gfx 1.21.0)" {
    // Guard the reproduction itself: `MockRender.getTextureInfo` MUST be
    // generic (return type references `self`), exactly like the production
    // `GfxRendererWith.getTextureInfo`. If someone "simplifies" it back to a
    // concrete return type this assertion fails and we'd stop covering the
    // regression at all.
    comptime {
        const ret = @typeInfo(@TypeOf(MockRender.getTextureInfo)).@"fn".return_type;
        std.debug.assert(ret == null); // null == generic == the broken shape
    }
    // Before v1.75.1 the whole `Game` type failed to COMPILE for this seam
    // (`tilemap_runtime.zig` reflected the generic wrapper's return type →
    // `error: unable to unwrap null`). It must now be supported so the null /
    // headless / real gfx backends all build with tilemaps functional.
    try testing.expect(engine.tilemapSupported(MockRender));
    try testing.expect(TilemapGame().TilemapRuntimeType != void);
}

/// A renderer that SPELLS all four seam decls but whose `TileMapRendererType`
/// carries no reflectable resolver/map — a bare or experimental backend.
/// `supported()` must reject it so the feature degrades to a compile-time
/// `void` no-op instead of failing inside `Runtime`.
const NonReflectableRender = struct {
    const Self = @This();
    pub const TileMapRendererType = struct {}; // no `map`, no `TextureResolver`
    pub fn loadTextureFromMemory(_: *Self, _: [:0]const u8, _: []const u8) !u32 {
        return 0;
    }
    pub fn getTextureInfo(_: *const Self, _: u32) ?u32 {
        return null;
    }
    pub fn unloadTexture(_: *Self, _: u32) void {}
};

test "supported() rejects a backend whose texture seam is not concretely reflectable" {
    // All four decls present, so the old `@hasDecl`-only gate would have said
    // true — but the seam can't be reflected into `Runtime`'s types.
    try testing.expect(!engine.tilemapSupported(NonReflectableRender));
    // A bare stub with none of the decls is likewise unsupported.
    try testing.expect(!engine.tilemapSupported(struct {}));
}

test "addTilemap decodes the .tmx into a per-entity runtime" {
    const G = TilemapGame();
    var game = G.init(testing.allocator);
    defer game.deinit();
    try registerFixture(&game);

    const e = game.createEntity();
    game.addTilemap(e, .{ .asset_name = "level.tmx" });

    // The component itself carries only the asset reference.
    const comp = game.getComponent(e, G.TilemapComp).?;
    try testing.expectEqualStrings("level.tmx", comp.asset_name);

    // The decoded map is reachable off the engine-side runtime.
    const rt = game.tilemapRuntime(e).?;
    try testing.expectEqual(@as(u32, 3), rt.map.width);
    try testing.expectEqual(@as(u32, 2), rt.map.height);
    try testing.expectEqual(@as(u32, 16), rt.map.tile_width);
    try testing.expectEqual(@as(usize, 1), rt.map.tile_layers.len);
    try testing.expectEqual(@as(usize, 1), rt.map.tilesets.len);
    try testing.expectEqualStrings("tiles.png", rt.map.tilesets[0].image_source);
}

test "tilemap renders as a PRE-SPRITE background pass at the entity's world offset" {
    const G = TilemapGame();
    var game = G.init(testing.allocator);
    defer game.deinit();
    try registerFixture(&game);

    const e = game.createEntity();
    game.setPosition(e, .{ .x = 100, .y = 50 });
    game.addTilemap(e, .{ .asset_name = "level.tmx" });

    const tileset_handle: u32 = 1; // first texture minted by the mock

    MockBackend.initMock(testing.allocator);
    defer MockBackend.deinitMock();

    game.render(); // tilemap BACKGROUND pass THEN sprite pass

    const calls = MockBackend.getDrawCalls();
    // Tilemap draws FIRST (background), sprite sentinel LAST — proves the
    // terrain renders UNDER the gameplay sprites (pre-sprite ordering).
    try testing.expect(calls.len >= 7);
    try testing.expectEqual(sprite_sentinel_id, calls[calls.len - 1].texture_id);

    var tile_draws: usize = 0;
    var min_x: f32 = std.math.floatMax(f32);
    var min_y: f32 = std.math.floatMax(f32);
    for (calls, 0..) |c, i| {
        if (c.texture_id == sprite_sentinel_id) {
            // The sentinel must be the very last draw — every tile precedes it.
            try testing.expectEqual(calls.len - 1, i);
            continue;
        }
        try testing.expectEqual(tileset_handle, c.texture_id);
        tile_draws += 1;
        if (c.dest.x < min_x) min_x = c.dest.x;
        if (c.dest.y < min_y) min_y = c.dest.y;
    }
    // 3×2 fully-populated layer → 6 tile draws.
    try testing.expectEqual(@as(usize, 6), tile_draws);
    // X is not flipped: tile (0,0) dest.x = 0*16 + offset_x(100) + 8 = 108.
    // This is the PRE-camera world→screen store offset (the camera matrix,
    // recorded as a pass below, applies the pan/zoom on top).
    try testing.expectEqual(@as(f32, 108), min_x);
    // Y IS flipped for the default `.up` project (F3): the map's top-left
    // screen offset = toScreenY(.up, 50, 600) - pixelHeight(32) = 518, so the
    // top row draws at 518 + 8 (centre) = 526.
    try testing.expectEqual(@as(f32, 526), min_y);
}

test "tilemap background pass runs INSIDE the world camera transform" {
    const G = TilemapGame();
    var game = G.init(testing.allocator);
    defer game.deinit();
    try registerFixture(&game);

    const e = game.createEntity();
    game.setPosition(e, .{ .x = 0, .y = 0 });
    game.addTilemap(e, .{ .asset_name = "level.tmx" });

    // Frame 1: camera at the origin. The tilemap pass must enter the camera
    // (one recorded backend camera pass) so tiles pan/zoom with the world.
    {
        MockBackend.initMock(testing.allocator);
        defer MockBackend.deinitMock();
        game.getCamera().setPosition(0, 0);
        game.render();

        const passes = MockBackend.getCameraPasses();
        try testing.expect(passes.len >= 1);
        // The pass carries the camera's target — proof the tilemap draws
        // under the SAME transform sprites use, not in raw screen space.
        try testing.expectEqual(@as(f32, 0), passes[0].target_x);
        try testing.expectEqual(@as(f32, 0), passes[0].target_y);
    }

    // Frame 2: pan the camera. The recorded transform must shift with it —
    // i.e. a camera pan moves the tilemap pass exactly as it moves sprites.
    {
        MockBackend.initMock(testing.allocator);
        defer MockBackend.deinitMock();
        game.getCamera().setPosition(200, 120);
        game.render();

        const passes = MockBackend.getCameraPasses();
        try testing.expect(passes.len >= 1);
        try testing.expectEqual(@as(f32, 200), passes[0].target_x);
        try testing.expectEqual(@as(f32, 120), passes[0].target_y);

        // The per-tile dest offsets stay in WORLD space (camera_x/y = 0):
        // the pan lives in the camera transform, NOT baked into the tile
        // positions — tile (0,0) dest.x is still 0*16 + offset_x(0) + 8 = 8,
        // unchanged by the pan.
        var min_x: f32 = std.math.floatMax(f32);
        for (MockBackend.getDrawCalls()) |c| {
            if (c.texture_id == sprite_sentinel_id) continue;
            if (c.dest.x < min_x) min_x = c.dest.x;
        }
        try testing.expectEqual(@as(f32, 8), min_x);
    }
}

test "save persists only asset_name; load rehydrates the runtime" {
    const G = TilemapGame();
    const filename = "test_tilemap_save.json";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, filename) catch {};

    // Save a game with one tilemap entity.
    {
        var game = G.init(testing.allocator);
        defer game.deinit();
        try registerFixture(&game);
        const e = game.createEntity();
        game.setPosition(e, .{ .x = 32, .y = 64 });
        game.addTilemap(e, .{ .asset_name = "level.tmx" });
        try game.saveGameState(filename);
    }

    // The save carries the asset reference, not per-tile data.
    {
        const json = try std.Io.Dir.cwd().readFileAlloc(
            std.testing.io,
            filename,
            testing.allocator,
            .limited(1 << 20),
        );
        defer testing.allocator.free(json);
        try testing.expect(std.mem.indexOf(u8, json, "\"Tilemap\"") != null);
        try testing.expect(std.mem.indexOf(u8, json, "level.tmx") != null);
        // No raw tile grid / gid CSV leaked into the save.
        try testing.expect(std.mem.indexOf(u8, json, "tile_layers") == null);
    }

    // Load into a fresh game: the component AND the decoded-map runtime
    // come back (runtime rebuilt from the still-embedded asset).
    {
        var game = G.init(testing.allocator);
        defer game.deinit();
        try registerFixture(&game);
        try game.loadGameState(filename);

        var found = false;
        var v = game.ecs_backend.view(.{core.Position}, .{});
        defer v.deinit();
        while (v.next()) |ent| {
            if (game.getComponent(ent, G.TilemapComp)) |tm| {
                try testing.expectEqualStrings("level.tmx", tm.asset_name);
                const rt = game.tilemapRuntime(ent).?;
                try testing.expectEqual(@as(u32, 3), rt.map.width);
                found = true;
            }
        }
        try testing.expect(found);
    }
}

test "save/load round-trips explicit layer_bindings (T3)" {
    const G = TilemapGame();
    const filename = "test_tilemap_bindings_save.json";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, filename) catch {};

    // Save a tilemap carrying an EXPLICIT binding list (the override that
    // does NOT derive from layer names — so it must persist or it silently
    // reverts to implicit-by-name on reload).
    {
        var game = G.init(testing.allocator);
        defer game.deinit();
        try registerFixture(&game);
        const e = game.createEntity();
        game.setPosition(e, .{ .x = 0, .y = 0 });
        const bindings = [_]engine.TilemapLayerBinding{
            .{ .tmx_layer = "ground", .engine_layer = "terrain" },
            .{ .tmx_layer = "tops", .engine_layer = "canopy" },
        };
        game.addTilemap(e, .{ .asset_name = "level.tmx", .layer_bindings = &bindings });
        try game.saveGameState(filename);
    }

    // Load into a fresh game: the explicit bindings come back intact.
    {
        var game = G.init(testing.allocator);
        defer game.deinit();
        try registerFixture(&game);
        try game.loadGameState(filename);

        var found = false;
        var v = game.ecs_backend.view(.{core.Position}, .{});
        defer v.deinit();
        while (v.next()) |ent| {
            if (game.getComponent(ent, G.TilemapComp)) |tm| {
                const lb = tm.layer_bindings orelse {
                    try testing.expect(false); // bindings were dropped
                    continue;
                };
                try testing.expectEqual(@as(usize, 2), lb.len);
                try testing.expectEqualStrings("ground", lb[0].tmx_layer);
                try testing.expectEqualStrings("terrain", lb[0].engine_layer);
                try testing.expectEqualStrings("tops", lb[1].tmx_layer);
                try testing.expectEqualStrings("canopy", lb[1].engine_layer);
                found = true;
            }
        }
        try testing.expect(found);
    }
}

test "scene digest reports the tilemap entity" {
    const G = TilemapGame();
    var game = G.init(testing.allocator);
    defer game.deinit();
    try registerFixture(&game);

    const e = game.createEntity();
    game.setPosition(e, .{ .x = 10, .y = 20 });
    game.addTilemap(e, .{ .asset_name = "level.tmx" });

    var runner = struct { ticks: u32 = 0 }{};
    editor_api.bind(&game, &runner);
    defer editor_api.unbind();

    var buf: [4096]u8 = undefined;
    const n = editor_api.editor_scene_digest(&buf, buf.len);
    const digest = buf[0..n];

    try testing.expect(std.mem.indexOf(u8, digest, "\"tilemap\":\"level.tmx\"") != null);
}

// A `.down` (screen-native) project — the tilemap y-flip is the identity.
fn TilemapGameDown() type {
    return engine.GameConfigWithYAxis(
        MockRender,
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
        .down,
    );
}

test "F3: tilemap y-offset matches the sprite y-axis transform (.up)" {
    const G = TilemapGame(); // default `.up`
    var game = G.init(testing.allocator);
    defer game.deinit();
    try registerFixture(&game);

    const pos_y: f32 = 50;
    const e = game.createEntity();
    game.setPosition(e, .{ .x = 0, .y = pos_y });
    game.addTilemap(e, .{ .asset_name = "level.tmx" });

    MockBackend.initMock(testing.allocator);
    defer MockBackend.deinitMock();
    game.render();

    // Tiles are recorded with a CENTRED dest (gfx anchors at the tile
    // centre), so the map's bottom edge = max centre-y + half a tile.
    const half_tile: f32 = 8;
    var max_center_y: f32 = -std.math.floatMax(f32);
    for (MockBackend.getDrawCalls()) |c| {
        if (c.texture_id == sprite_sentinel_id) continue; // skip sprite pass
        if (c.dest.y > max_center_y) max_center_y = c.dest.y;
    }
    const map_bottom_edge = max_center_y + half_tile;

    // The tilemap's bottom edge must land exactly where the renderer's own
    // y-flip (the SAME path sprites use) places `Position.y`.
    const sprite_screen_y = core.toScreenY(.up, pos_y, game.renderer.screen_height);
    try testing.expectEqual(sprite_screen_y, map_bottom_edge);
}

test "F3: tilemap y-offset is the identity under .down" {
    const G = TilemapGameDown();
    var game = G.init(testing.allocator);
    defer game.deinit();
    try registerFixture(&game);

    const e = game.createEntity();
    game.setPosition(e, .{ .x = 0, .y = 50 });
    game.addTilemap(e, .{ .asset_name = "level.tmx" });

    MockBackend.initMock(testing.allocator);
    defer MockBackend.deinitMock();
    game.render();

    // `.down`: offset_y = Position.y (identity, no height adjust). Top-left
    // tile (0,0) centre = 0*16 + 50 + 8 = 58.
    var min_y: f32 = std.math.floatMax(f32);
    for (MockBackend.getDrawCalls()) |c| {
        if (c.texture_id == sprite_sentinel_id) continue; // skip sprite pass
        if (c.dest.y < min_y) min_y = c.dest.y;
    }
    try testing.expectEqual(@as(f32, 58), min_y);
}

test "F1: tileset textures are released on teardown (no GPU-texture leak)" {
    const G = TilemapGame();
    var game = G.init(testing.allocator);
    defer game.deinit();
    try registerFixture(&game);

    const e = game.createEntity();
    game.addTilemap(e, .{ .asset_name = "level.tmx" });
    // One tileset image uploaded → one live backend texture.
    try testing.expectEqual(@as(usize, 1), game.renderer.textures.count());

    // Re-acquire must not grow the texture registry (old released first).
    game.acquireTilemap(e, "level.tmx");
    try testing.expectEqual(@as(usize, 1), game.renderer.textures.count());

    // Release unloads the uploaded texture — no leak.
    game.releaseTilemap(e);
    try testing.expectEqual(@as(usize, 0), game.renderer.textures.count());
}

test "F4: removeTilemap frees the runtime and detaches the component" {
    const G = TilemapGame();
    var game = G.init(testing.allocator);
    defer game.deinit();
    try registerFixture(&game);

    const e = game.createEntity();
    game.addTilemap(e, .{ .asset_name = "level.tmx" });
    try testing.expect(game.tilemapRuntime(e) != null);

    game.removeTilemap(e);
    try testing.expect(game.tilemapRuntime(e) == null);
    try testing.expect(game.getComponent(e, G.TilemapComp) == null);
    try testing.expectEqual(@as(usize, 0), game.renderer.textures.count());
}

test "F4: generic removeComponent leaves no drawing ghost (render reaps it)" {
    const G = TilemapGame();
    var game = G.init(testing.allocator);
    defer game.deinit();
    try registerFixture(&game);

    const e = game.createEntity();
    game.setPosition(e, .{ .x = 0, .y = 0 });
    game.addTilemap(e, .{ .asset_name = "level.tmx" });
    try testing.expect(game.tilemapRuntime(e) != null);

    // Strip the component the "wrong" way (generic removeComponent) — the
    // side-table runtime is now an orphan.
    game.removeComponent(e, G.TilemapComp);

    MockBackend.initMock(testing.allocator);
    defer MockBackend.deinitMock();
    game.render(); // reaps the ghost, draws only the sprite sentinel

    // No tile draws — the ghost never rendered.
    try testing.expectEqual(@as(usize, 1), MockBackend.getDrawCallCount());
    try testing.expectEqual(sprite_sentinel_id, MockBackend.getDrawCalls()[0].texture_id);
    // And the orphan runtime + its texture were reaped/freed.
    try testing.expect(game.tilemapRuntime(e) == null);
    try testing.expectEqual(@as(usize, 0), game.renderer.textures.count());
}
