//! `Game.setSpriteFrame` — the wrapped atlas frame swap that bundles
//! `sprite.sprite_name = name` + re-resolved `source_rect` / `texture` +
//! `renderer.markVisualDirty(entity)`.
//!
//! Background (#826): assigning `sprite_name` on its own renders the OLD
//! frame, because the renderer draws from `source_rect` + `texture` and
//! nothing re-resolves those until the next `resolveAtlasSprites` pass. So
//! every animation script grew a private `resolveSprite` helper — the same
//! twelve lines copy-pasted five times across flying-platform-labelle,
//! ricochet, and the WFC demo, one of them carrying a comment pointing at
//! another copy.
//!
//! The correctness trap those copies all fell into is the reason this file
//! exists: `FindSpriteResult` carries `texture_scale_x/y`, `< 1` for an
//! atlas whose PNG shipped downscaled, and NONE of the five applies it —
//! they read `found.sprite.x/y/getWidth()/getHeight()` raw and silently
//! sample outside the real texture. `setSpriteFrame` delegates to
//! `sourceRectFor`, the same pure mapping `resolveAtlasSprites` uses, so
//! the scale can only ever be applied one way.
//!
//! Coverage:
//! - happy path: the swap writes `sprite_name`, `source_rect` and
//!   `texture`, and bumps `markVisualDirty` exactly once.
//! - SCALE (the bug being fixed): on a downscaled atlas the source rect's
//!   x/y/w/h are multiplied by `texture_scale_*` while the DISPLAY dims
//!   stay un-scaled. This is the assertion the five hand-rolled copies fail.
//! - unresolved name: `source_rect` / `texture` untouched, no dirty-mark,
//!   but `sprite_name` IS stamped so the per-frame resolver can self-heal
//!   once the atlas loads.
//! - missing-Sprite: returns silently, dirty counter stays at zero.
//! - comptime no-op: a renderer whose `Sprite` lacks the atlas trio still
//!   compiles and runs through the helper as a no-op.
//!
//! Uses a local `FrameRenderer` rather than `StubRender` for the same
//! reason `set_sprite_flip_test.zig` does: StubRender's `Sprite` doesn't
//! carry the fields under test, and its `markVisualDirty` has no
//! observable side effect.

const std = @import("std");
const testing = std.testing;
const core = @import("labelle-core");
const engine = @import("engine");

const MockEcs = core.MockEcsBackend(u32);

/// Minimal renderer carrying the atlas trio `setSpriteFrame` writes
/// (`sprite_name` / `source_rect` / `texture`) plus a `markVisualDirty`
/// that increments a test-observable counter.
fn FrameRenderer(comptime Entity: type) type {
    return struct {
        const Self = @This();

        /// Field-for-field stand-in for labelle-gfx's `SourceRect`; the real
        /// one lives outside this repo (mirrors `atlas_source_rect_test.zig`).
        pub const SourceRect = struct {
            x: f32 = 0,
            y: f32 = 0,
            width: f32 = 0,
            height: f32 = 0,
            display_width: f32 = 0,
            display_height: f32 = 0,
        };

        pub const TextureId = enum(u32) { none = 0, _ };

        pub const Sprite = struct {
            sprite_name: []const u8 = "",
            source_rect: ?SourceRect = null,
            texture: TextureId = .none,
            visible: bool = true,
            z_index: i16 = 0,
            layer: enum { default } = .default,
        };

        pub const Shape = struct {
            visible: bool = true,
            z_index: i16 = 0,
            layer: enum { default } = .default,
        };

        visual_dirty_count: usize = 0,

        pub fn init(_: std.mem.Allocator) Self {
            return .{};
        }
        pub fn deinit(_: *Self) void {}
        pub fn trackEntity(_: *Self, _: Entity, _: core.VisualType) void {}
        pub fn untrackEntity(_: *Self, _: Entity) void {}
        pub fn markPositionDirty(_: *Self, _: Entity) void {}
        pub fn markPositionDirtyWithChildren(_: *Self, comptime _: type, _: anytype, _: Entity) void {}
        pub fn updateHierarchyFlag(_: *Self, _: Entity, _: bool) void {}
        pub fn markVisualDirty(self: *Self, _: Entity) void {
            self.visual_dirty_count += 1;
        }
        pub fn sync(_: *Self, comptime _: type, _: anytype) void {}
        pub fn render(_: *Self) void {}
        pub fn setScreenHeight(_: *Self, _: f32) void {}
        pub fn clear(_: *Self) void {}
        pub fn renderGizmoDraws(_: *Self, _: []const core.GizmoDraw) void {}
        pub fn hasEntity(_: *const Self, _: Entity) bool {
            return false;
        }
    };
}

const EmptyComponents = struct {
    pub fn has(comptime _: []const u8) bool {
        return false;
    }
    pub fn names() []const []const u8 {
        return &.{};
    }
};

const TestGame = engine.GameConfig(
    FrameRenderer(MockEcs.Entity),
    MockEcs,
    engine.StubInput,
    engine.StubAudio,
    engine.StubVideo,
    engine.StubGui,
    void,
    engine.StubLogSink,
    EmptyComponents,
    &.{},
    void,
);

const Sprite = TestGame.SpriteComp;
const FrameTextureId = FrameRenderer(MockEcs.Entity).TextureId;

/// Seed a two-frame atlas. `scale` is the JSON-logical → texture-pixel
/// ratio: `1.0` for a 1:1 atlas, `0.5` for a PNG shipped at half size
/// without re-running TexturePacker.
fn seedAtlas(game: *TestGame, scale: f32) !void {
    const atlas = try game.getTextureManager().addAtlas("chars");
    atlas.texture_id = 7;
    atlas.texture_scale_x = scale;
    atlas.texture_scale_y = scale;
    // Frame keys are string literals — `addAtlas` doesn't own its keys.
    try atlas.addSprite("idle_0001.png", .{ .x = 0, .y = 0, .width = 32, .height = 32 });
    try atlas.addSprite("walk_0002.png", .{ .x = 64, .y = 32, .width = 32, .height = 48 });
}

test "setSpriteFrame: swaps the frame's source_rect, texture and name" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    try seedAtlas(&game, 1.0);

    const entity = game.createEntity();
    game.addSprite(entity, .{ .sprite_name = "idle_0001.png" });
    const dirty_before = game.renderer.visual_dirty_count;

    game.setSpriteFrame(entity, "walk_0002.png");

    const sprite = game.getComponent(entity, Sprite).?;
    try testing.expectEqualStrings("walk_0002.png", sprite.sprite_name);
    try testing.expectEqual(@as(FrameTextureId, @enumFromInt(7)), sprite.texture);

    // The whole point: `source_rect` tracks the NEW frame, not the old one.
    const rect = sprite.source_rect.?;
    try testing.expectEqual(@as(f32, 64), rect.x);
    try testing.expectEqual(@as(f32, 32), rect.y);
    try testing.expectEqual(@as(f32, 32), rect.width);
    try testing.expectEqual(@as(f32, 48), rect.height);

    // Forgetting the dirty-mark was the silent half of the hand-rolled
    // helper: the fields update but the renderer keeps the stale visual.
    try testing.expectEqual(dirty_before + 1, game.renderer.visual_dirty_count);
}

test "setSpriteFrame: applies texture_scale to the source rect but not the display dims" {
    // THE regression guard for #826. On a downscaled atlas the texture-pixel
    // coords must shrink with the PNG while the design-space display dims
    // stay put. All five hand-rolled `resolveSprite` copies skip the scale
    // entirely, so they would report x=64/width=32 here and sample from
    // outside the 0.5x texture — no error, just the wrong pixels.
    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    try seedAtlas(&game, 0.5);

    const entity = game.createEntity();
    game.addSprite(entity, .{ .sprite_name = "idle_0001.png" });

    game.setSpriteFrame(entity, "walk_0002.png");

    const rect = game.getComponent(entity, Sprite).?.source_rect.?;
    // Physical atlas footprint — scaled onto the smaller texture.
    try testing.expectEqual(@as(f32, 32), rect.x);
    try testing.expectEqual(@as(f32, 16), rect.y);
    try testing.expectEqual(@as(f32, 16), rect.width);
    try testing.expectEqual(@as(f32, 24), rect.height);
    // Display dimensions are design-space: UN-scaled, or the sprite would
    // also shrink on screen when an artist swaps in a lighter PNG.
    try testing.expectEqual(@as(f32, 32), rect.display_width);
    try testing.expectEqual(@as(f32, 48), rect.display_height);
}

test "setSpriteFrame: unknown name leaves geometry alone and does not mark dirty" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    try seedAtlas(&game, 1.0);

    const entity = game.createEntity();
    game.addSprite(entity, .{ .sprite_name = "idle_0001.png" });
    game.setSpriteFrame(entity, "walk_0002.png");
    const dirty_before = game.renderer.visual_dirty_count;
    const rect_before = game.getComponent(entity, Sprite).?.source_rect.?;

    game.setSpriteFrame(entity, "not_in_any_atlas.png");

    const sprite = game.getComponent(entity, Sprite).?;
    // Geometry untouched — a failed resolve must never blank the sprite.
    try testing.expectEqual(rect_before.x, sprite.source_rect.?.x);
    try testing.expectEqual(rect_before.width, sprite.source_rect.?.width);
    try testing.expectEqual(@as(FrameTextureId, @enumFromInt(7)), sprite.texture);
    try testing.expectEqual(dirty_before, game.renderer.visual_dirty_count);
    // ...but the NAME is stamped, so `resolveAtlasSprites` resolves it on a
    // later frame if the atlas that owns it is still loading.
    try testing.expectEqualStrings("not_in_any_atlas.png", sprite.sprite_name);
}

test "setSpriteFrame: entity without Sprite returns silently" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();
    try seedAtlas(&game, 1.0);

    // No `addSprite` — the entity has no Sprite component.
    const entity = game.createEntity();
    const dirty_before = game.renderer.visual_dirty_count;

    // Must not panic, must not mark dirty (matches `setSpriteFlip`).
    game.setSpriteFrame(entity, "walk_0002.png");

    try testing.expectEqual(dirty_before, game.renderer.visual_dirty_count);
}

/// Renderer whose `Sprite` carries none of the atlas trio — exercises the
/// `comptime has_atlas_sprite_fields` guard. Mirror of `FrameRenderer`
/// minus `source_rect` / `texture`.
fn PlainRenderer(comptime Entity: type) type {
    return struct {
        const Self = @This();

        pub const Sprite = struct {
            visible: bool = true,
            z_index: i16 = 0,
            layer: enum { default } = .default,
        };

        pub const Shape = struct {
            visible: bool = true,
            z_index: i16 = 0,
            layer: enum { default } = .default,
        };

        visual_dirty_count: usize = 0,

        pub fn init(_: std.mem.Allocator) Self {
            return .{};
        }
        pub fn deinit(_: *Self) void {}
        pub fn trackEntity(_: *Self, _: Entity, _: core.VisualType) void {}
        pub fn untrackEntity(_: *Self, _: Entity) void {}
        pub fn markPositionDirty(_: *Self, _: Entity) void {}
        pub fn markPositionDirtyWithChildren(_: *Self, comptime _: type, _: anytype, _: Entity) void {}
        pub fn updateHierarchyFlag(_: *Self, _: Entity, _: bool) void {}
        pub fn markVisualDirty(self: *Self, _: Entity) void {
            self.visual_dirty_count += 1;
        }
        pub fn sync(_: *Self, comptime _: type, _: anytype) void {}
        pub fn render(_: *Self) void {}
        pub fn setScreenHeight(_: *Self, _: f32) void {}
        pub fn clear(_: *Self) void {}
        pub fn renderGizmoDraws(_: *Self, _: []const core.GizmoDraw) void {}
        pub fn hasEntity(_: *const Self, _: Entity) bool {
            return false;
        }
    };
}

const PlainGame = engine.GameConfig(
    PlainRenderer(MockEcs.Entity),
    MockEcs,
    engine.StubInput,
    engine.StubAudio,
    engine.StubVideo,
    engine.StubGui,
    void,
    engine.StubLogSink,
    EmptyComponents,
    &.{},
    void,
);

test "setSpriteFrame: comptime no-op when Sprite has no atlas fields" {
    var game = PlainGame.init(testing.allocator);
    defer game.deinit();

    const entity = game.createEntity();
    game.addSprite(entity, .{});
    const dirty_before = game.renderer.visual_dirty_count;

    // The point of this test is the *compile*: a backend whose Sprite has
    // no `source_rect` / `texture` (StubRender, custom mocks) must still be
    // able to call `setSpriteFrame` without a type error. At runtime the
    // dirty-count stays at zero.
    game.setSpriteFrame(entity, "walk_0002.png");

    try testing.expectEqual(dirty_before, game.renderer.visual_dirty_count);
}
