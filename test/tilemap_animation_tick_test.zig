//! Tiled per-tile animations, driven from the frame tick (companion to
//! labelle-gfx#351).
//!
//! gfx's tilemap renderer deliberately owns NO clock: backends disagree
//! about how to read one and a headless test must be deterministic, so
//! `TileMapRenderer.advanceAnimations(dt_seconds)` is the only thing that
//! moves a `<tile><animation>`. This suite pins the engine half — that
//! `Game.tick` calls it once per frame, on the SAME time-scaled dt
//! `sprite_animation_tick` and `particles_tick` take, so a pause freezes
//! the water and a slowed time-scale slows it.
//!
//! ## Why this suite does not use the real gfx `tilemap` package
//!
//! `advanceAnimations` lives on labelle-gfx#352, which is not released;
//! `build.zig.zon` pins gfx v1.31.0, whose tilemap renderer has no such
//! decl. The engine reaches gfx purely by reflection through the renderer
//! plugin, so the honest stand-in is a renderer seam shaped exactly like
//! gfx's — `FakeGfx(true)` is the post-#351 shape and `FakeGfx(false)` the
//! pre-#351 one, both driven through the real `Game` / `tilemap_runtime` /
//! `loop_mixin` code path.
//!
//! That pairing is the point of the `@hasDecl` gate: the tick is gated on
//! the DECL, not on `supported()`, so an engine built against older gfx
//! keeps its tilemaps and merely does not animate them. The legacy half of
//! this suite is what pins that.

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

/// The `.tmx` bytes are never parsed here (see `FakeGfx.TileMap`), but the
/// asset must be REGISTERED for `acquireTilemap` to build a runtime at all,
/// so the fixture stays a real document rather than a placeholder.
const water_tmx =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<map version="1.10" orientation="orthogonal" width="2" height="1" tilewidth="16" tileheight="16">
    \\ <tileset firstgid="1" name="water" tilewidth="16" tileheight="16" columns="4" tilecount="8">
    \\  <image source="tiles.png" width="64" height="32"/>
    \\  <tile id="0">
    \\   <animation>
    \\    <frame tileid="0" duration="240"/>
    \\    <frame tileid="4" duration="240"/>
    \\   </animation>
    \\  </tile>
    \\ </tileset>
    \\ <layer name="ground" width="2" height="1">
    \\  <data encoding="csv">1,1</data>
    \\ </layer>
    \\</map>
;

const fake_png = "\x89PNG\r\n\x1a\n fake tileset pixels";

// ── gfx stand-in ────────────────────────────────────────────────────────

/// `with_anim` selects the gfx generation: `true` ships
/// `advanceAnimations` (labelle-gfx#351), `false` is every gfx before it.
fn FakeGfx(comptime with_anim: bool) type {
    return struct {
        const Gfx = @This();

        pub const Texture = struct { id: u32 };

        pub const Tileset = struct {
            firstgid: u32 = 1,
            name: []const u8 = "water",
            tile_width: u32 = 16,
            tile_height: u32 = 16,
            columns: u32 = 4,
            tile_count: u32 = 8,
            image_source: []const u8 = "tiles.png",
            image_width: u32 = 64,
            image_height: u32 = 32,
        };

        pub const TileLayer = struct {
            name: []const u8 = "ground",
            width: u32 = 2,
            height: u32 = 1,
            data: []u32 = &.{},

            pub fn getTile(self: *const TileLayer, x: u32, y: u32) u32 {
                return self.data[y * self.width + x];
            }
        };

        /// Stands in for gfx's `TileMap` decoder. The `.tmx` bytes are
        /// IGNORED: this suite is about who calls the animation tick and
        /// with what dt, not about decoding — gfx's own suite covers the
        /// parse, and a hand-rolled parser here would only pin itself.
        pub const TileMap = struct {
            allocator: std.mem.Allocator,
            width: u32 = 2,
            height: u32 = 1,
            tile_width: u32 = 16,
            tile_height: u32 = 16,
            tilesets: []Tileset = &.{},
            tile_layers: []TileLayer = &.{},

            pub fn loadFromMemoryWithBasePath(
                allocator: std.mem.Allocator,
                bytes: []const u8,
                base_path: []const u8,
            ) !TileMap {
                _ = bytes;
                _ = base_path;
                var map = TileMap{ .allocator = allocator };
                map.tilesets = try allocator.alloc(Tileset, 1);
                errdefer allocator.free(map.tilesets);
                map.tilesets[0] = .{};

                const data = try allocator.alloc(u32, 2);
                errdefer allocator.free(data);
                data[0] = 1;
                data[1] = 1;

                map.tile_layers = try allocator.alloc(TileLayer, 1);
                map.tile_layers[0] = .{ .data = data };
                return map;
            }

            pub fn deinit(self: *TileMap) void {
                self.allocator.free(self.tilesets);
                for (self.tile_layers) |l| self.allocator.free(l.data);
                self.allocator.free(self.tile_layers);
            }

            pub fn getPixelHeight(self: *const TileMap) u32 {
                return self.height * self.tile_height;
            }
        };

        /// Stands in for `TileMapRendererWith(Backend)`.
        ///
        /// TWO distinct types rather than one type with a conditional
        /// decl: `@hasDecl` is what the engine gates on, and a decl
        /// declared as `if (with_anim) f else {}` EXISTS either way (as
        /// `void`), so the gate would read `true` for both generations and
        /// the legacy half of this suite would test nothing. Two types is
        /// also the truth of the situation — these are two gfx releases.
        pub const TileMapRenderer = if (with_anim) AnimatedRenderer else LegacyRenderer;

        /// Shared by both renderer generations. Named apart from the
        /// per-renderer `TextureResolver`/`InitOptions` decls below — the
        /// engine reflects those OFF THE RENDERER, so each type must carry
        /// them, and a same-named outer decl would shadow ambiguously.
        const SharedResolver = struct {
            context: ?*anyopaque = null,
            resolveFn: *const fn (context: ?*anyopaque, tileset_index: usize, tileset: *const Tileset) ?Texture,
        };

        const SharedInitOptions = struct {
            resolver: ?SharedResolver = null,
            load_unresolved_from_filesystem: bool = true,
        };

        /// gfx before labelle-gfx#351: draws, and has no clock at all.
        const LegacyRenderer = struct {
            pub const TextureResolver = Gfx.SharedResolver;
            pub const InitOptions = Gfx.SharedInitOptions;

            allocator: std.mem.Allocator,
            map: *const TileMap,
            sheet: ?Texture = null,
            draws: usize = 0,

            pub fn initWithOptions(
                allocator: std.mem.Allocator,
                map: *const TileMap,
                options: InitOptions,
            ) !LegacyRenderer {
                var self = LegacyRenderer{ .allocator = allocator, .map = map };
                if (options.resolver) |r| self.sheet = r.resolveFn(r.context, 0, &map.tilesets[0]);
                return self;
            }

            pub fn deinit(_: *LegacyRenderer) void {}

            pub fn drawAllLayers(self: *LegacyRenderer, _: f32, _: f32, _: anytype) void {
                self.draws += 1;
            }

            pub fn drawLayerDirect(self: *LegacyRenderer, _: *const TileLayer, _: f32, _: f32, _: anytype) void {
                self.draws += 1;
            }
        };

        /// gfx WITH labelle-gfx#351. Models just enough playback to be
        /// worth asserting: one 2-frame, 240ms-per-frame animation on gid
        /// 1, advanced the way gfx advances it (accumulate, wrap, resolve),
        /// plus the gid a draw would emit for it.
        const AnimatedRenderer = struct {
            pub const TextureResolver = Gfx.SharedResolver;
            pub const InitOptions = Gfx.SharedInitOptions;

            const frame_ms: f32 = 240;
            const cycle_ms: f32 = 480;

            allocator: std.mem.Allocator,
            map: *const TileMap,
            sheet: ?Texture = null,
            /// How many times the engine called `advanceAnimations`.
            ticks: usize = 0,
            /// Sum of every dt it passed — what proves the tick rides the
            /// game's TIME-SCALED delta and not the raw frame delta.
            total_dt: f32 = 0,
            elapsed_ms: f32 = 0,
            /// The gid the draw pass would emit for placed gid 1.
            drawn_gid: u32 = 1,
            draws: usize = 0,

            pub fn initWithOptions(
                allocator: std.mem.Allocator,
                map: *const TileMap,
                options: InitOptions,
            ) !AnimatedRenderer {
                var self = AnimatedRenderer{ .allocator = allocator, .map = map };
                if (options.resolver) |r| self.sheet = r.resolveFn(r.context, 0, &map.tilesets[0]);
                return self;
            }

            pub fn deinit(_: *AnimatedRenderer) void {}

            pub fn drawAllLayers(self: *AnimatedRenderer, _: f32, _: f32, _: anytype) void {
                self.draws += 1;
            }

            pub fn drawLayerDirect(self: *AnimatedRenderer, _: *const TileLayer, _: f32, _: f32, _: anytype) void {
                self.draws += 1;
            }

            pub fn advanceAnimations(self: *AnimatedRenderer, dt: f32) void {
                self.ticks += 1;
                self.total_dt += dt;
                if (!(dt > 0)) return;
                self.elapsed_ms = @mod(self.elapsed_ms + dt * 1000.0, cycle_ms);
                self.drawn_gid = if (self.elapsed_ms < frame_ms) 1 else 5;
            }
        };
    };
}

// ── Renderer plugin ─────────────────────────────────────────────────────

fn FakeRender(comptime with_anim: bool) type {
    return struct {
        const Self = @This();
        const Gfx = FakeGfx(with_anim);

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
            return id;
        }
        // Generic return type (it references `self`), exactly like the
        // production `GfxRendererWith` — this keeps the v1.75.1
        // null-backend reflection shape under test here too.
        pub fn getTextureInfo(self: *const Self, id: u32) ?@TypeOf(self.inner).TextureInfo {
            if (!self.live.contains(id)) return null;
            return .{ .backend_texture = .{ .id = id } };
        }
        pub fn unloadTexture(self: *Self, id: u32) void {
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

fn AnimGame(comptime with_anim: bool) type {
    return GameConfig(
        FakeRender(with_anim),
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

const ModernGame = AnimGame(true);
const LegacyGame = AnimGame(false);

/// A game with one tilemap entity on the animated fixture.
fn spawnTilemap(game: anytype) !u32 {
    try game.addEmbeddedTilemapAsset("level.tmx", water_tmx);
    try game.addEmbeddedTilemapAsset("tiles.png", fake_png);
    const e = game.createEntity();
    game.addTilemap(e, .{ .asset_name = "level.tmx" });
    return e;
}

// ── Tests ───────────────────────────────────────────────────────────────

test "the frame tick advances a tilemap's animations" {
    var game = ModernGame.init(testing.allocator);
    defer game.deinit();
    const e = try spawnTilemap(&game);

    const rt = game.tilemapRuntime(e) orelse return error.NoTilemapRuntime;
    try testing.expectEqual(@as(usize, 0), rt.tm.ticks);

    game.tick(0.1);
    try testing.expectEqual(@as(usize, 1), rt.tm.ticks);
    try testing.expectApproxEqAbs(@as(f32, 0.1), rt.tm.total_dt, 1e-6);

    game.tick(0.1);
    try testing.expectEqual(@as(usize, 2), rt.tm.ticks);
    try testing.expectApproxEqAbs(@as(f32, 0.2), rt.tm.total_dt, 1e-6);
}

test "ticking long enough flips the drawn frame, and it wraps" {
    var game = ModernGame.init(testing.allocator);
    defer game.deinit();
    const e = try spawnTilemap(&game);
    const rt = game.tilemapRuntime(e) orelse return error.NoTilemapRuntime;

    // Frames are 240ms; 12 frames at 60fps is 200ms — still frame 0.
    var i: usize = 0;
    while (i < 12) : (i += 1) game.tick(1.0 / 60.0);
    try testing.expectEqual(@as(u32, 1), rt.tm.drawn_gid);

    // Past 240ms → frame 1.
    while (i < 20) : (i += 1) game.tick(1.0 / 60.0);
    try testing.expectEqual(@as(u32, 5), rt.tm.drawn_gid);

    // Past 480ms → wrapped back to frame 0.
    while (i < 32) : (i += 1) game.tick(1.0 / 60.0);
    try testing.expectEqual(@as(u32, 1), rt.tm.drawn_gid);
}

test "the tick rides the time-scaled dt, like sprite animation" {
    var game = ModernGame.init(testing.allocator);
    defer game.deinit();
    const e = try spawnTilemap(&game);
    const rt = game.tilemapRuntime(e) orelse return error.NoTilemapRuntime;

    game.setTimeScale(0.5);
    game.tick(0.2);
    // Slow-mo slows the water: half a frame's worth of time reaches gfx.
    try testing.expectApproxEqAbs(@as(f32, 0.1), rt.tm.total_dt, 1e-6);

    game.setTimeScale(2.0);
    game.tick(0.2);
    try testing.expectApproxEqAbs(@as(f32, 0.5), rt.tm.total_dt, 1e-6);
}

test "a hard pause freezes the animation instead of ticking it" {
    var game = ModernGame.init(testing.allocator);
    defer game.deinit();
    const e = try spawnTilemap(&game);
    const rt = game.tilemapRuntime(e) orelse return error.NoTilemapRuntime;

    // `time_scale = 0` zeroes the scaled dt, so the tick is skipped
    // outright — the same guard the sprite and particle ticks sit behind.
    game.setTimeScale(0);
    var i: usize = 0;
    while (i < 60) : (i += 1) game.tick(1.0 / 60.0);
    try testing.expectEqual(@as(usize, 0), rt.tm.ticks);
    try testing.expectEqual(@as(u32, 1), rt.tm.drawn_gid);

    // And it resumes exactly where it left off once time runs again.
    game.setTimeScale(1);
    game.tick(0.3);
    try testing.expectEqual(@as(usize, 1), rt.tm.ticks);
    try testing.expectEqual(@as(u32, 5), rt.tm.drawn_gid);
}

test "every tilemap entity is advanced, each on its own state" {
    var game = ModernGame.init(testing.allocator);
    defer game.deinit();
    try game.addEmbeddedTilemapAsset("level.tmx", water_tmx);
    try game.addEmbeddedTilemapAsset("tiles.png", fake_png);

    const a = game.createEntity();
    game.addTilemap(a, .{ .asset_name = "level.tmx" });
    game.tick(0.3); // `a` alone exists for this frame

    const b = game.createEntity();
    game.addTilemap(b, .{ .asset_name = "level.tmx" });
    game.tick(0.1);

    const rt_a = game.tilemapRuntime(a) orelse return error.NoTilemapRuntime;
    const rt_b = game.tilemapRuntime(b) orelse return error.NoTilemapRuntime;
    try testing.expectEqual(@as(usize, 2), rt_a.tm.ticks);
    try testing.expectEqual(@as(usize, 1), rt_b.tm.ticks);
    // Playback is per MAP, so the later map is not dragged to the older
    // one's cycle position.
    try testing.expectEqual(@as(u32, 5), rt_a.tm.drawn_gid);
    try testing.expectEqual(@as(u32, 1), rt_b.tm.drawn_gid);
}

test "a removed tilemap stops being ticked" {
    var game = ModernGame.init(testing.allocator);
    defer game.deinit();
    const e = try spawnTilemap(&game);

    game.tick(0.1);
    game.removeTilemap(e);
    try testing.expectEqual(@as(?*ModernGame.TilemapRuntimeType, null), game.tilemapRuntime(e));

    // The walk is over the live side table, so a freed runtime is never
    // reached — this would be a use-after-free if it were.
    game.tick(0.1);
}

test "a game with no tilemap ticks nothing" {
    var game = ModernGame.init(testing.allocator);
    defer game.deinit();

    const e = game.createEntity();
    game.setPosition(e, .{ .x = 0, .y = 0 });

    var i: usize = 0;
    while (i < 10) : (i += 1) game.tick(1.0 / 60.0);
    // Nothing to assert but the absence of a crash and of work: the empty
    // side table short-circuits before the iterator is even built.
    try testing.expectEqual(@as(usize, 0), game.tilemaps.count());
}

// ── The pre-#351 gfx generation ─────────────────────────────────────────

test "an engine on older gfx keeps its tilemaps and simply does not animate" {
    // The gate is on the DECL, not on `supported()` — widening
    // `supported()` would cost such a build the whole tilemap feature
    // rather than just the animation.
    try testing.expect(engine.tilemapSupported(FakeRender(false)));
    try testing.expect(LegacyGame.tilemap_supported);
    try testing.expect(!LegacyGame.TilemapRuntimeType.animations_supported);
    try testing.expect(ModernGame.TilemapRuntimeType.animations_supported);

    var game = LegacyGame.init(testing.allocator);
    defer game.deinit();
    const e = try spawnTilemap(&game);

    // Ticking is a comptime no-op here; the map still decodes and still
    // draws, which is the whole additive-degrade contract.
    var i: usize = 0;
    while (i < 30) : (i += 1) game.tick(1.0 / 60.0);

    const rt = game.tilemapRuntime(e) orelse return error.NoTilemapRuntime;
    try testing.expectEqual(@as(usize, 1), rt.map.tile_layers.len);

    game.render();
    try testing.expect(rt.tm.draws > 0);
}

test "setPaused alone keeps animating, exactly like the neighbouring ticks" {
    var game = ModernGame.init(testing.allocator);
    defer game.deinit();
    const e = try spawnTilemap(&game);
    const rt = game.tilemapRuntime(e) orelse return error.NoTilemapRuntime;

    // `setPaused(true)` sets the flag and LEAVES `time_scale` at 1.0, so
    // `scaled_dt` stays non-zero. That is deliberate and matches the two
    // ticks this one sits beside in `loop_mixin.tick`'s always-run block:
    // `sprite_animation_tick` gates on `drive_sprite_animations and
    // !sprite_animations_paused and scaled_dt != 0`, and `particles_tick`
    // on `drive_particles and scaled_dt != 0` — NEITHER consults `paused`
    // / `isPaused()`. `isPaused()` gates the gameplay-skip section further
    // down, not this block. A pause menu that wants everything frozen uses
    // `Game.pause()`, which zeroes `time_scale` (covered above).
    //
    // This test exists so that consistency is pinned rather than
    // rediscovered: change it only by changing all three ticks together.
    game.setPaused(true);
    try testing.expect(game.isPaused());
    game.tick(0.3);
    try testing.expectEqual(@as(usize, 1), rt.tm.ticks);
    try testing.expectEqual(@as(u32, 5), rt.tm.drawn_gid);

    // `pause()` — the flag AND `time_scale = 0` — does freeze it.
    game.pause();
    game.tick(0.3);
    try testing.expectEqual(@as(usize, 1), rt.tm.ticks);
}
