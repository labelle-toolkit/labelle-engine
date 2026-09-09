//! Shared test support for the T3 tilemap Z-interleave suite.
//!
//! Holds the hook-capable renderer mocks, `.tmx` fixtures, `Game` builders,
//! and draw-record helpers used by `tilemap_interleave_test.zig` (interleave /
//! binding / gate behavior) and `tilemap_percamera_test.zig` (per-camera cull
//! + background + reap). Kept in one place so the two test binaries share the
//! exact same mock contract. Path-imported by both (no `test` blocks here).

const std = @import("std");

const engine = @import("engine");
const core = @import("labelle-core");
const tilemap = @import("tilemap");

pub const GameConfig = engine.GameConfig;
pub const MockEcsBackend = engine.MockEcsBackend;
pub const StubInput = engine.StubInput;
pub const StubAudio = engine.StubAudio;
pub const StubVideo = engine.StubVideo;
pub const StubGui = engine.StubGui;
pub const StubLogSink = engine.StubLogSink;

pub const MockBackend = core.mock_backend.MockBackend;

// ── Fixtures ────────────────────────────────────────────────────────────

// terrain (3×2 full → 6 tiles) UNDER canopy (2 non-zero gids). Both names
// match a WORLD engine layer → both interleave.
pub const terrain_canopy_tmx =
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

// Single `ground` layer — matches NO engine layer → fully UNBOUND (T2
// background fallback).
pub const ground_tmx =
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

// terrain (name-matches → implicitly bound) + foliage (no match → unbound
// unless explicitly bound). foliage has 3 tiles.
pub const terrain_foliage_tmx =
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

pub const fake_png = "\x89PNG\r\n\x1a\n fake tileset pixels";

/// Every tile draw uses the first minted texture handle (the single tileset).
pub const tileset_handle: u32 = 1;

// ── Engine layer stack + camera ───────────────────────────────────────────

/// z-order low → high: terrain, actors, canopy are WORLD; hud is SCREEN. A
/// sprite layer (`actors`) sits between terrain and canopy.
pub const LayerEnum = enum {
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

pub const sentinel_base: u32 = 90000;
pub fn layerSentinel(comptime l: LayerEnum) u32 {
    return sentinel_base + @intFromEnum(l);
}

/// Minimal world camera mirroring gfx's `CameraWith` begin/end + getViewport.
/// `getViewport` returns the visible WORLD rect (Y-up), centered on the camera
/// — the shape the engine's per-camera cull reads.
pub const MockCamera = struct {
    x: f32 = 0,
    y: f32 = 0,
    zoom: f32 = 1,
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

// ── Hook-capable renderer mock (gfx ≥1.24.0 dual hook) ────────────────────

pub const HookRender = struct {
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
    /// True while a `renderWithLayerHooks` call is in flight — lets a test
    /// prove that texture unloads (ghost reaping) happen OUTSIDE the render
    /// loop, not inside a per-camera draw hook (codex #712).
    in_render: bool = false,
    /// Count of `unloadTexture` calls that landed WHILE `in_render` — must be
    /// 0 once reaping is hoisted to a pre-render step.
    unloads_during_render: usize = 0,

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
        if (self.in_render) self.unloads_during_render += 1;
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
        self.in_render = true;
        defer self.in_render = false;
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

    /// gfx v1.22.0 single-hook seam — delegates with a no-op before-hook.
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

pub const EmptyComponents = struct {
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

pub fn InterleaveGame() type {
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

pub fn sentinelIndex(calls: anytype, id: u32) ?usize {
    for (calls, 0..) |c, i| {
        if (c.texture_id == id) return i;
    }
    return null;
}

/// Count tile draws (texture_id == the tileset handle) whose index falls in
/// the half-open range [lo, hi).
pub fn tileDrawsInRange(calls: anytype, lo: usize, hi: usize) usize {
    var n: usize = 0;
    for (calls, 0..) |c, i| {
        if (i < lo or i >= hi) continue;
        if (c.texture_id == tileset_handle) n += 1;
    }
    return n;
}

pub fn totalTileDraws(calls: anytype) usize {
    var n: usize = 0;
    for (calls) |c| {
        if (c.texture_id == tileset_handle) n += 1;
    }
    return n;
}

/// Build a `w×h` `.tmx` with the given `layer_names`, every cell gid 1 — a
/// large map for the per-camera cull regressions. Caller frees.
pub fn buildFullTmx(alloc: std.mem.Allocator, w: u32, h: u32, layer_names: []const []const u8) ![]const u8 {
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

// ── Gate-only mocks ───────────────────────────────────────────────────────

/// Declares `renderWithLayerHook` + the tilemap seam, but `Layer = void`
/// (NOT a config enum). The interleave gate must reject it.
pub const BadLayerRender = struct {
    const Self = @This();

    pub const Layer = void;

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

pub fn BadLayerGame() type {
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

/// Has `renderWithLayerHook` (interleave) + a valid config `Layer`, but NOT
/// the dual-hook `renderWithLayerHooks` — the gfx 1.22–1.23 shape. The gate
/// must report interleave-supported but per-camera-background UNsupported.
pub const OldHookRender = struct {
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

pub fn OldHookGame() type {
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
