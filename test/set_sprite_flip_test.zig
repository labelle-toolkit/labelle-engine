//! `Game.setSpriteFlip` — the wrapped sprite-flip mutation that bundles
//! `sprite.flip_x = X` + `renderer.markVisualDirty(entity)`.
//!
//! Background: downstream call sites used to write this pair by hand
//! across worker_animation / worker_controller / hunger_hooks /
//! ship_animation, and forgetting the dirty-mark was a silent bug —
//! the field would update but the renderer wouldn't pick up the
//! visual change until something else (position move, frame flip)
//! re-dirtied the entity. Mirrors `setZIndex` / `setPosition` in
//! `src/game/visuals.zig`.
//!
//! Coverage:
//! - happy path: helper writes `flip_x` AND bumps the renderer's
//!   `markVisualDirty` invocation counter exactly once.
//! - idempotent: calling with the value the sprite already has must
//!   short-circuit — neither write nor dirty-mark fires.
//! - missing-Sprite: the helper returns silently rather than panicking;
//!   the dirty-mark counter stays at zero.
//! - comptime no-op: a renderer whose `Sprite` lacks a `flip_x` field
//!   (StubRender, custom mocks) still compiles and runs through the
//!   helper as a no-op — the `@hasField` guard catches it before any
//!   field access.
//!
//! Uses a local `FlipRenderer` instead of `StubRender` because
//! StubRender's `Sprite` doesn't carry a `flip_x` field (and its
//! `markVisualDirty` is a pure no-op with no observable side effect).
//! Adding the field + a counter to StubRender would require a
//! labelle-core change; the local renderer keeps this PR
//! engine-only.

const std = @import("std");
const testing = std.testing;
const core = @import("labelle-core");
const engine = @import("engine");

const MockEcs = core.MockEcsBackend(u32);

/// Minimal renderer with the bits `setSpriteFlip` actually touches:
/// a `Sprite.flip_x` field to mutate, and a `markVisualDirty` that
/// increments a test-observable counter.
fn FlipRenderer(comptime Entity: type) type {
    return struct {
        const Self = @This();

        pub const Sprite = struct {
            sprite_name: []const u8 = "",
            visible: bool = true,
            z_index: i16 = 0,
            flip_x: bool = false,
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
    FlipRenderer(MockEcs.Entity),
    MockEcs,
    engine.StubInput,
    engine.StubAudio,
    engine.StubGui,
    void,
    engine.StubLogSink,
    EmptyComponents,
    &.{},
    void,
);

const Sprite = TestGame.SpriteComp;

test "setSpriteFlip: writes flip_x and marks visual dirty" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const entity = game.createEntity();
    game.addSprite(entity, .{ .sprite_name = "worker", .flip_x = false });

    // Baseline: addSprite tracks the entity but doesn't mark it dirty.
    const dirty_before = game.renderer.visual_dirty_count;

    game.setSpriteFlip(entity, true);

    const sprite = game.getComponent(entity, Sprite).?;
    try testing.expect(sprite.flip_x);
    try testing.expectEqual(dirty_before + 1, game.renderer.visual_dirty_count);
}

test "setSpriteFlip: no-op when flip already matches (no dirty-mark)" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const entity = game.createEntity();
    game.addSprite(entity, .{ .sprite_name = "worker", .flip_x = true });

    const dirty_before = game.renderer.visual_dirty_count;

    // Same value → short-circuit. The dirty-mark is the load-bearing
    // observation here: a naive "always write + always mark" impl would
    // bump the counter and waste a render-side resync.
    game.setSpriteFlip(entity, true);

    const sprite = game.getComponent(entity, Sprite).?;
    try testing.expect(sprite.flip_x);
    try testing.expectEqual(dirty_before, game.renderer.visual_dirty_count);
}

test "setSpriteFlip: entity without Sprite returns silently" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    // No `addSprite` — the entity has no Sprite component.
    const entity = game.createEntity();

    const dirty_before = game.renderer.visual_dirty_count;

    // Must not panic, must not mark dirty. Callers that need an
    // assertion can `getComponent` first; the helper's defensive
    // posture matches `setZIndex` (which silently skips missing
    // visuals).
    game.setSpriteFlip(entity, true);

    try testing.expectEqual(dirty_before, game.renderer.visual_dirty_count);
}

/// Renderer whose `Sprite` has no `flip_x` field — exercises the
/// `comptime @hasField(Sprite, "flip_x")` guard at the top of the
/// helper. Mirror of `FlipRenderer` minus the field.
fn NoFlipRenderer(comptime Entity: type) type {
    return struct {
        const Self = @This();

        pub const Sprite = struct {
            sprite_name: []const u8 = "",
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

const NoFlipGame = engine.GameConfig(
    NoFlipRenderer(MockEcs.Entity),
    MockEcs,
    engine.StubInput,
    engine.StubAudio,
    engine.StubGui,
    void,
    engine.StubLogSink,
    EmptyComponents,
    &.{},
    void,
);

test "setSpriteFlip: comptime no-op when Sprite has no flip_x field" {
    var game = NoFlipGame.init(testing.allocator);
    defer game.deinit();

    const entity = game.createEntity();
    game.addSprite(entity, .{ .sprite_name = "worker" });

    const dirty_before = game.renderer.visual_dirty_count;

    // The point of this test is the *compile*: a backend whose Sprite
    // doesn't have `flip_x` (StubRender, custom mocks) must still be
    // able to call `setSpriteFlip` without a type error. The
    // `@hasField` guard short-circuits before any field access. At
    // runtime, dirty-count stays at zero.
    game.setSpriteFlip(entity, true);

    try testing.expectEqual(dirty_before, game.renderer.visual_dirty_count);
}
