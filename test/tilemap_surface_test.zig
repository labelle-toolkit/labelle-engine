//! Tileset textures across a GPU surface loss / restore (#847).
//!
//! A tilemap's textures — the per-tileset SHEET and, for a collection-of-
//! images tileset, every per-tile image — are uploaded by
//! `tilemap_runtime.initInPlace` straight through the renderer, so the
//! engine's direct-upload re-arm (#820, `World.direct_textures`) never saw
//! them: after Android TERM_WINDOW / INIT_WINDOW the ids resolved to
//! nothing and every layer drew blank.
//!
//! These tests drive the REAL `Game.surfaceLost` / `Game.surfaceRestored`
//! entry points against a renderer that models gfx's minted-key registry
//! (`invalidateTexture` / `reuploadTextureFromMemory`, labelle-gfx#345)
//! and records every call, so they assert the mechanism — which ids were
//! invalidated, which were re-uploaded under the SAME id with which bytes,
//! that nothing was freed through a dead handle, and that gfx's tilemap
//! renderer was re-bound to the fresh backend textures — not merely that
//! the cycle didn't crash.

const std = @import("std");
const testing = std.testing;

const engine = @import("engine");
const core = @import("labelle-core");

const FakeGfx = @import("tilemap_fake_gfx.zig").FakeGfx;

// ── Fixtures ────────────────────────────────────────────────────────────

/// One sheet tileset AND one collection tileset (two distinct per-tile
/// images, one of them named twice) — every upload shape in one map.
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
    \\  <tile id="1">
    \\   <image source="rock.png" width="16" height="16"/>
    \\  </tile>
    \\  <tile id="2">
    \\   <image source="tree.png" width="32" height="48"/>
    \\  </tile>
    \\ </tileset>
    \\ <layer name="ground" width="3" height="2">
    \\  <data encoding="csv">
    \\1,2,9,
    \\10,11,0,
    \\</data>
    \\ </layer>
    \\</map>
;

// Distinct bytes per image, so a re-upload can be tied back to its source.
const tiles_png = "\x89PNG tiles-sheet";
const tree_png = "\x89PNG tree";
const rock_png = "\x89PNG rock";

// ── Call ledger (file-scope: read after `game.deinit`) ──────────────────

const Call = struct { id: u32, bytes: []const u8 = "" };

var uploads: std.ArrayList(Call) = .empty;
var invalidations: std.ArrayList(u32) = .empty;
var reuploads: std.ArrayList(Call) = .empty;
var unloads: std.ArrayList(u32) = .empty;
/// `unloadTexture` on an id whose backend handle was still resident — a
/// real backend destroy. During a surface cycle this is the #820 bug.
var backend_frees: std.ArrayList(u32) = .empty;
/// Makes `reuploadTextureFromMemory` fail for exactly these bytes.
var fail_reupload_of: ?[]const u8 = null;

fn clearLedger() void {
    inline for (.{ &uploads, &reuploads }) |l| {
        l.deinit(testing.allocator);
        l.* = .empty;
    }
    inline for (.{ &invalidations, &unloads, &backend_frees }) |l| {
        l.deinit(testing.allocator);
        l.* = .empty;
    }
    fail_reupload_of = null;
}

fn countIn(list: []const u32, id: u32) usize {
    var n: usize = 0;
    for (list) |x| n += @intFromBool(x == id);
    return n;
}

// ── Renderer plugin ─────────────────────────────────────────────────────

/// gfx-shaped renderer over `FakeGfx(true)` WITH the minted-key re-arm
/// pair (`invalidateTexture` + `reuploadTextureFromMemory`). The seam-less
/// degrade is pinned in `tilemap_collection_test.zig`, whose renderer is
/// exactly a pre-labelle-gfx#345 one.
const SurfaceRender = struct {
    const Self = @This();
    const Gfx = FakeGfx(true);

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

    /// A registry entry: the backend generation behind the key, and
    /// whether that backend handle is alive (gfx's `gpu_resident`).
    const Entry = struct { gen: u32, resident: bool };

    inner: Inner = .{},
    alloc: std.mem.Allocator = undefined,
    entries: std.AutoHashMapUnmanaged(u32, Entry) = .empty,
    next_id: u32 = 1,
    next_gen: u32 = 1,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .alloc = allocator };
    }
    pub fn deinit(self: *Self) void {
        self.entries.deinit(self.alloc);
    }

    pub fn loadTextureFromMemory(self: *Self, file_type: [:0]const u8, data: []const u8) !u32 {
        _ = file_type;
        const id = self.next_id;
        self.next_id += 1;
        try self.entries.put(self.alloc, id, .{ .gen = self.next_gen, .resident = true });
        self.next_gen += 1;
        try uploads.append(testing.allocator, .{ .id = id, .bytes = data });
        return id;
    }
    pub fn getTextureInfo(self: *const Self, id: u32) ?@TypeOf(self.inner).TextureInfo {
        const e = self.entries.get(id) orelse return null;
        if (!e.resident) return null;
        return .{ .backend_texture = .{ .id = id, .gen = e.gen } };
    }
    pub fn unloadTexture(self: *Self, id: u32) void {
        unloads.append(testing.allocator, id) catch @panic("OOM");
        if (self.entries.fetchRemove(id)) |kv| {
            if (kv.value.resident) backend_frees.append(testing.allocator, id) catch @panic("OOM");
        }
    }

    pub fn invalidateTexture(self: *Self, id: u32) void {
        invalidations.append(testing.allocator, id) catch @panic("OOM");
        if (self.entries.getPtr(id)) |e| e.resident = false;
    }
    pub fn reuploadTextureFromMemory(self: *Self, id: u32, file_type: [:0]const u8, data: []const u8) !void {
        _ = file_type;
        if (fail_reupload_of) |bad| {
            if (std.mem.eql(u8, bad, data)) return error.DecodeFailed;
        }
        const e = self.entries.getPtr(id) orelse return error.TextureNotRegistered;
        e.* = .{ .gen = self.next_gen, .resident = true };
        self.next_gen += 1;
        try reuploads.append(testing.allocator, .{ .id = id, .bytes = data });
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

const SeamGame = engine.GameConfig(
    SurfaceRender,
    engine.MockEcsBackend(u32),
    engine.StubInput,
    engine.StubAudio,
    engine.StubVideo,
    engine.StubGui,
    void, // Hooks
    engine.StubLogSink,
    EmptyComponents,
    &.{}, // gizmo categories
    void, // game events
);

fn registerAssets(game: anytype) !void {
    try game.addEmbeddedTilemapAsset("level.tmx", mixed_tmx);
    try game.addEmbeddedTilemapAsset("tiles.png", tiles_png);
    try game.addEmbeddedTilemapAsset("tree.png", tree_png);
    try game.addEmbeddedTilemapAsset("rock.png", rock_png);
}

/// The backend generation gfx's tilemap renderer currently HOLDS for the
/// sheet and each per-tile image — what a draw would actually sample.
fn heldGens(rt: anytype, out: []u32) void {
    out[0] = (rt.tm.sheet[0] orelse return).gen;
    for (rt.tm.tiles, 0..) |t, k| out[1 + k] = if (t) |tex| tex.gen else 0;
}

// ── Tests ───────────────────────────────────────────────────────────────

test "surface cycle re-uploads sheet AND per-tile textures under their original ids" {
    defer clearLedger();
    try testing.expect(SeamGame.TilemapRuntimeType.surface_reload_supported);
    var game = SeamGame.init(testing.allocator);
    defer game.deinit();
    try registerAssets(&game);

    const e = game.createEntity();
    game.addTilemap(e, .{ .asset_name = "level.tmx" });
    const rt = game.tilemapRuntime(e) orelse return error.NoTilemapRuntime;

    // Sheet + two distinct per-tile images (tree shared by two tiles).
    try testing.expectEqual(@as(usize, 3), rt.owned_ids.len);
    try testing.expectEqual(@as(usize, 3), uploads.items.len);
    const sheet_id = rt.tileset_ids[0].?;
    const tree_id = rt.tile_ids[0].?;
    const rock_id = rt.tile_ids[1].?;
    try testing.expectEqual(tree_id, rt.tile_ids[2].?);

    var before: [4]u32 = undefined;
    heldGens(rt, &before);

    game.surfaceLost();

    // Every owned id invalidated exactly once — never unloaded (the
    // context is gone; freeing through it is the #820 bug).
    try testing.expectEqual(@as(usize, 3), invalidations.items.len);
    for (rt.owned_ids) |id| try testing.expectEqual(@as(usize, 1), countIn(invalidations.items, id));
    try testing.expectEqual(@as(usize, 0), unloads.items.len);
    try testing.expect(rt.surface_lost);

    // While the surface is gone the map is NOT drawn: `tm` holds dead
    // backend handles.
    const draws_before = rt.tm.draws;
    game.renderTilemaps();
    try testing.expectEqual(draws_before, rt.tm.draws);

    game.surfaceRestored();

    // Re-uploaded through the re-arm seam — SAME ids, each with the bytes
    // of the image it was first decoded from — and NOT through a fresh
    // `loadTextureFromMemory` (which would mint new ids).
    try testing.expectEqual(@as(usize, 3), uploads.items.len);
    try testing.expectEqual(@as(usize, 3), reuploads.items.len);
    for (reuploads.items) |call| {
        const want: []const u8 = if (call.id == sheet_id)
            tiles_png
        else if (call.id == tree_id)
            tree_png
        else if (call.id == rock_id)
            rock_png
        else
            return error.UnexpectedReuploadId;
        try testing.expectEqualStrings(want, call.bytes);
    }
    try testing.expectEqual(sheet_id, rt.tileset_ids[0].?);
    try testing.expectEqual(tree_id, rt.tile_ids[0].?);
    try testing.expectEqual(rock_id, rt.tile_ids[1].?);

    // gfx's tilemap renderer was RE-BOUND: it now holds the fresh backend
    // textures (new generation) for the sheet and every tile, not the
    // dead ones it cached at init.
    var after: [4]u32 = undefined;
    heldGens(rt, &after);
    for (before, after) |b, a| {
        try testing.expect(a != 0);
        try testing.expect(a != b);
    }
    try testing.expectEqual(after[1], after[3]); // shared source, one texture

    // ...and draws again.
    try testing.expect(!rt.surface_lost);
    game.renderTilemaps();
    try testing.expectEqual(draws_before + 1, rt.tm.draws);
    try testing.expectEqual(@as(usize, 0), backend_frees.items.len);
}

test "runtime tile edits survive the surface cycle" {
    defer clearLedger();
    var game = SeamGame.init(testing.allocator);
    defer game.deinit();
    try registerAssets(&game);

    const e = game.createEntity();
    game.addTilemap(e, .{ .asset_name = "level.tmx" });
    const rt = game.tilemapRuntime(e) orelse return error.NoTilemapRuntime;
    const map_ptr = &rt.map;

    try testing.expect(rt.setTile(0, 2, 1, 5));
    game.surfaceLost();
    game.surfaceRestored();

    // The decoded map is kept (not re-decoded from the `.tmx`), so the
    // edit is still there and the renderer points at the same map.
    try testing.expectEqual(game.tilemapRuntime(e).?, rt);
    try testing.expectEqual(@as(u32, 5), rt.map.tile_layers[0].data[1 * 3 + 2]);
    try testing.expectEqual(@as(*const @TypeOf(rt.map), map_ptr), rt.tm.map);
}

test "teardown after a restore frees each id once, through a live handle" {
    defer clearLedger();
    var owned: [3]u32 = undefined;
    {
        var game = SeamGame.init(testing.allocator);
        defer game.deinit();
        try registerAssets(&game);
        const e = game.createEntity();
        game.addTilemap(e, .{ .asset_name = "level.tmx" });
        const rt = game.tilemapRuntime(e) orelse return error.NoTilemapRuntime;
        @memcpy(&owned, rt.owned_ids);
        game.surfaceLost();
        game.surfaceRestored();
    }
    try testing.expectEqual(@as(usize, 3), unloads.items.len);
    for (owned) |id| {
        try testing.expectEqual(@as(usize, 1), countIn(unloads.items, id));
        try testing.expectEqual(@as(usize, 1), countIn(backend_frees.items, id));
    }
}

test "a tilemap released while the surface is gone frees no dead handle" {
    defer clearLedger();
    var game = SeamGame.init(testing.allocator);
    defer game.deinit();
    try registerAssets(&game);
    const e = game.createEntity();
    game.addTilemap(e, .{ .asset_name = "level.tmx" });

    game.surfaceLost();
    game.removeTilemap(e);

    // The keys are dropped from the registry, but no backend destroy went
    // through the dead context; the restore then has nothing to re-upload.
    try testing.expectEqual(@as(usize, 3), unloads.items.len);
    try testing.expectEqual(@as(usize, 0), backend_frees.items.len);
    game.surfaceRestored();
    try testing.expectEqual(@as(usize, 0), reuploads.items.len);
}

test "a failed re-upload blanks only that texture; the map still draws" {
    defer clearLedger();
    var game = SeamGame.init(testing.allocator);
    defer game.deinit();
    try registerAssets(&game);
    const e = game.createEntity();
    game.addTilemap(e, .{ .asset_name = "level.tmx" });
    const rt = game.tilemapRuntime(e) orelse return error.NoTilemapRuntime;

    fail_reupload_of = rock_png;
    game.surfaceLost();
    game.surfaceRestored();

    try testing.expectEqual(@as(usize, 2), reuploads.items.len);
    try testing.expect(!rt.surface_lost);
    try testing.expect(rt.tm.sheet[0] != null);
    try testing.expect(rt.tm.tiles[0] != null); // tree
    try testing.expect(rt.tm.tiles[1] == null); // rock: still invalidated
    const draws = rt.tm.draws;
    game.renderTilemaps();
    try testing.expectEqual(draws + 1, rt.tm.draws);
}

test "restore without a prior loss re-uploads nothing" {
    defer clearLedger();
    var game = SeamGame.init(testing.allocator);
    defer game.deinit();
    try registerAssets(&game);
    const e = game.createEntity();
    game.addTilemap(e, .{ .asset_name = "level.tmx" });

    game.surfaceRestored();
    try testing.expectEqual(@as(usize, 0), reuploads.items.len);
    try testing.expectEqual(@as(usize, 0), game.reloadTilemapTextures());
}
