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
//! production `GfxRendererWith` exposes those exact decls.

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
/// test can prove tilemap tiles are drawn strictly AFTER it (post-sprite).
const sprite_sentinel_id: u32 = 90001;

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
    pub const TextureInfo = struct { backend_texture: MockBackend.Texture };

    alloc: std.mem.Allocator = undefined,
    textures: std.AutoHashMapUnmanaged(u32, MockBackend.Texture) = .empty,
    next_id: u32 = 1,
    render_count: usize = 0,

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
    pub fn getTextureInfo(self: *const Self, id: u32) ?TextureInfo {
        const tex = self.textures.get(id) orelse return null;
        return .{ .backend_texture = tex };
    }

    // ── core.RenderInterface no-ops (mirror StubRender) ──
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

test "tilemap renders as a POST-SPRITE pass at the entity's world offset" {
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

    game.render(); // sprite pass (sentinel) THEN tilemap pass

    const calls = MockBackend.getDrawCalls();
    // Sprite pass first, tiles after — proves post-sprite ordering.
    try testing.expect(calls.len >= 7);
    try testing.expectEqual(sprite_sentinel_id, calls[0].texture_id);

    var tile_draws: usize = 0;
    var min_x: f32 = std.math.floatMax(f32);
    var min_y: f32 = std.math.floatMax(f32);
    for (calls[1..]) |c| {
        try testing.expectEqual(tileset_handle, c.texture_id);
        tile_draws += 1;
        if (c.dest.x < min_x) min_x = c.dest.x;
        if (c.dest.y < min_y) min_y = c.dest.y;
    }
    // 3×2 fully-populated layer → 6 tile draws.
    try testing.expectEqual(@as(usize, 6), tile_draws);
    // Top-left tile (0,0): dest = tile*16 + offset - camera, centred (+8).
    // offset = entity Position (100,50), camera 0 → 108 / 58.
    try testing.expectEqual(@as(f32, 108), min_x);
    try testing.expectEqual(@as(f32, 58), min_y);
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
