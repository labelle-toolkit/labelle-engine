//! `Game.setMaterial` / `Game.clearMaterial` — the game-facing per-entity
//! material authoring surface for the labelle-gfx#305 curated shader effects
//! (flash / palette_swap / dissolve / outline).
//!
//! Background: the material seam is renderer-complete — the `Material` value
//! type lives in `labelle-core` (`backend_contract.Material`), gfx carries it
//! INLINE on `SpriteVisual.material`, and the bgfx backend renders the full
//! curated set (with `materialSupported` graceful degrade). But before this the
//! engine exposed NO way for a game to SET a material on a sprite entity — no
//! `Sprite.material` authoring, no `setMaterial` API. This closes that gap by
//! mirroring `setSpriteFlip`: material rides on the sprite component like
//! `tint` / `flip_x`, so the runtime setter and the declarative
//! `.Sprite = .{ .material = … }` scene path feed the same field.
//!
//! Coverage:
//! - happy path: `setMaterial` writes `sprite.material` AND bumps
//!   `markVisualDirty` exactly once.
//! - idempotent: setting the material the sprite already has short-circuits —
//!   neither write nor dirty-mark fires (a wasted material re-submit breaks the
//!   backend's draw batch, so the short-circuit is load-bearing).
//! - `clearMaterial`: resets to `.effect == .none` (the plain-sprite fast path)
//!   and marks dirty.
//! - declarative parity: a material authored INLINE on the `addSprite` literal
//!   (the runtime mirror of `.Sprite = .{ .material = … }` in a `.zon`) lands on
//!   the component with no setter call — proving the field-on-Sprite authoring
//!   surface, not a separate component.
//! - missing-Sprite: the setter returns silently rather than panicking.
//! - comptime no-op: a renderer whose `Sprite` lacks a `material` field
//!   (StubRender, older gfx, custom mocks) still compiles and runs the setter as
//!   a no-op — the `@hasField` guard catches it before any field access.
//!
//! Uses a local `MaterialRenderer` (mirroring `set_sprite_flip_test`'s
//! `FlipRenderer`): its `Sprite` carries a real `material` field plus a
//! `markVisualDirty` counter, keeping this PR engine-only.

const std = @import("std");
const testing = std.testing;
const core = @import("labelle-core");
const engine = @import("engine");

const Material = core.backend_contract.Material;
const MockEcs = core.MockEcsBackend(u32);

/// Minimal renderer with exactly the bits `setMaterial` touches: a
/// `Sprite.material` field to mutate (the same nominal
/// `backend_contract.Material` gfx carries on `SpriteVisual`) and a
/// `markVisualDirty` that increments a test-observable counter.
fn MaterialRenderer(comptime Entity: type) type {
    return struct {
        const Self = @This();

        pub const Sprite = struct {
            sprite_name: []const u8 = "",
            visible: bool = true,
            z_index: i16 = 0,
            material: Material = .{},
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
    MaterialRenderer(MockEcs.Entity),
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

const flash_red: Material = .{
    .effect = .flash,
    .uniforms = .{ .r = 1, .g = 0, .b = 0, .a = 1, .scalar0 = 0.6 },
};

test "setMaterial: writes material and marks visual dirty" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const entity = game.createEntity();
    game.addSprite(entity, .{ .sprite_name = "worker" });

    // Baseline: a fresh sprite defaults to the no-material fast path.
    const sprite0 = game.getComponent(entity, Sprite).?;
    try testing.expectEqual(core.backend_contract.MaterialEffect.none, sprite0.material.effect);

    const dirty_before = game.renderer.visual_dirty_count;

    game.setMaterial(entity, flash_red);

    const sprite = game.getComponent(entity, Sprite).?;
    try testing.expectEqual(core.backend_contract.MaterialEffect.flash, sprite.material.effect);
    try testing.expectEqual(@as(f32, 0.6), sprite.material.uniforms.scalar0);
    try testing.expectEqual(dirty_before + 1, game.renderer.visual_dirty_count);
}

test "setMaterial: no-op when material already matches (no dirty-mark)" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const entity = game.createEntity();
    game.addSprite(entity, .{ .sprite_name = "worker", .material = flash_red });

    const dirty_before = game.renderer.visual_dirty_count;

    // Same value → short-circuit. A material re-submit breaks the backend draw
    // batch, so a naive "always write + always mark" would waste a resync.
    game.setMaterial(entity, flash_red);

    const sprite = game.getComponent(entity, Sprite).?;
    try testing.expectEqual(core.backend_contract.MaterialEffect.flash, sprite.material.effect);
    try testing.expectEqual(dirty_before, game.renderer.visual_dirty_count);
}

test "clearMaterial: resets to .none fast path and marks dirty" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const entity = game.createEntity();
    game.addSprite(entity, .{ .sprite_name = "worker", .material = flash_red });

    const dirty_before = game.renderer.visual_dirty_count;

    game.clearMaterial(entity);

    const sprite = game.getComponent(entity, Sprite).?;
    try testing.expectEqual(core.backend_contract.MaterialEffect.none, sprite.material.effect);
    try testing.expectEqual(dirty_before + 1, game.renderer.visual_dirty_count);
}

test "clearMaterial: no-op when already unmaterialed (no dirty-mark)" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const entity = game.createEntity();
    game.addSprite(entity, .{ .sprite_name = "worker" });

    const dirty_before = game.renderer.visual_dirty_count;

    game.clearMaterial(entity);

    try testing.expectEqual(dirty_before, game.renderer.visual_dirty_count);
}

test "declarative: material authored inline on the sprite component lands with no setter" {
    // The runtime mirror of `.Sprite = .{ .material = … }` in a scene/prefab
    // `.zon`: because material rides on the sprite component (not a separate
    // ECS component), authoring it on the `addSprite` literal is sufficient —
    // no `setMaterial` call, no component registration.
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const entity = game.createEntity();
    game.addSprite(entity, .{
        .sprite_name = "hero",
        .material = .{ .effect = .outline, .uniforms = .{ .scalar0 = 2.0 } },
    });

    const sprite = game.getComponent(entity, Sprite).?;
    try testing.expectEqual(core.backend_contract.MaterialEffect.outline, sprite.material.effect);
    try testing.expectEqual(@as(f32, 2.0), sprite.material.uniforms.scalar0);
}

test "setMaterial: entity without Sprite returns silently" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    // No `addSprite` — the entity has no Sprite component.
    const entity = game.createEntity();

    const dirty_before = game.renderer.visual_dirty_count;

    game.setMaterial(entity, flash_red);
    game.clearMaterial(entity);

    try testing.expectEqual(dirty_before, game.renderer.visual_dirty_count);
}

test "engine re-exports name the same nominal Material type as core" {
    // `engine.Material` must be the very type gfx carries on `Sprite.material`,
    // so a game can write `engine.Material{ … }` and hand it straight to
    // `setMaterial` / a `.zon`.
    try testing.expect(engine.Material == core.backend_contract.Material);
    try testing.expect(engine.MaterialEffect == core.backend_contract.MaterialEffect);
    try testing.expect(engine.MaterialUniforms == core.backend_contract.MaterialUniforms);
}

/// Renderer whose `Sprite` has no `material` field — exercises the
/// `comptime @hasField(Sprite, "material")` guard. Mirror of `MaterialRenderer`
/// minus the field (StubRender / older gfx / custom mocks).
fn NoMaterialRenderer(comptime Entity: type) type {
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

const NoMaterialGame = engine.GameConfig(
    NoMaterialRenderer(MockEcs.Entity),
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

test "setMaterial: comptime no-op when Sprite has no material field" {
    var game = NoMaterialGame.init(testing.allocator);
    defer game.deinit();

    const entity = game.createEntity();
    game.addSprite(entity, .{ .sprite_name = "worker" });

    const dirty_before = game.renderer.visual_dirty_count;

    // The point is the *compile*: a renderer whose Sprite has no `material`
    // (StubRender, older gfx, custom mocks) must still call setMaterial /
    // clearMaterial without a type error. The `@hasField` guard short-circuits
    // before any field access; at runtime dirty-count stays at zero.
    game.setMaterial(entity, flash_red);
    game.clearMaterial(entity);

    try testing.expectEqual(dirty_before, game.renderer.visual_dirty_count);
}
