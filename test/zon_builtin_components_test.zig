//! #881 — the comptime `.zon` entity writer must never silently drop an
//! engine BUILT-IN component.
//!
//! Before the fix `EntityWriter.addComponents` dispatched `Sprite` and
//! `Shape` by name and then fell through to `Components.has(...)`, which
//! only ever covers PROJECT-registered components. A `.zon`-authored
//! `Camera`, `Image` or `Emitter` therefore matched no branch and fell off
//! the end of the chain: the entity spawned, the component never existed,
//! and not one diagnostic was emitted anywhere.
//!
//! Every test below asserts the component is PRESENT (and carries the
//! authored values) after the write. Asserting only that the entity exists
//! would pass against the bug and prove nothing.
//!
//! The completeness half of the fix — a NEW built-in that forgets a writer
//! branch failing to COMPILE — is pinned by
//! `EntityWriter(...).builtin_dispatch_complete`, which forces the writer's
//! exhaustive `handlerFor` switch over `scene.builtins.Builtin` for every
//! tag at instantiation time.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const core = @import("labelle-core");
const scene = @import("scene");

const Ecs = core.MockEcsBackend(u32);
const Render = core.StubRender(u32);

/// A registry with no components at all — the shape that made the bug
/// visible: `has()` is false for everything, so a built-in that is not
/// special-cased by name has nowhere left to go.
const NoComponents = struct {
    pub fn has(comptime _: []const u8) bool {
        return false;
    }
    pub fn names() []const []const u8 {
        return &.{};
    }
};

/// A project-registered `Camera` that must SHADOW the engine built-in
/// (the `.zon` mirror of `component_apply.zig`'s `!Components.has("Camera")`
/// gate).
const ProjectCamera = struct { rig: u32 = 0 };

const ShadowingComponents = struct {
    pub fn has(comptime name: []const u8) bool {
        return std.mem.eql(u8, name, "Camera");
    }
    pub fn names() []const []const u8 {
        return &.{"Camera"};
    }
    pub fn getType(comptime name: []const u8) type {
        if (std.mem.eql(u8, name, "Camera")) return ProjectCamera;
        @compileError("no such component: " ++ name);
    }
};

fn GameWith(comptime Components: type) type {
    return engine.GameConfig(
        Render,
        Ecs,
        engine.StubInput,
        engine.StubAudio,
        engine.StubVideo,
        engine.StubGui,
        void,
        core.StubLogSink,
        Components,
        &.{},
        void,
    );
}

const Game = GameWith(NoComponents);
const Writer = scene.EntityWriter(Game, NoComponents);

const ShadowGame = GameWith(ShadowingComponents);
const ShadowWriter = scene.EntityWriter(ShadowGame, ShadowingComponents);

// ── The three built-ins #881 found dropped ──────────────────────────────

test "zon-authored Camera lands on the entity with its authored zoom and tag" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    const e = game.createEntity();

    _ = Writer.addComponents(e, &game, .{ .Camera = .{ .zoom = 2.5, .tag = "sky_parallax" } }, null);

    const cam = game.ecs_backend.getComponent(e, Game.CameraComp) orelse
        return error.CameraComponentDropped;
    try testing.expectEqual(@as(f32, 2.5), cam.zoom);
    // The inline `[16:0]u8` tag is exactly what a generic coercion cannot
    // fill from a `.zon` string — assert the authored value reached it.
    try testing.expectEqualStrings("sky_parallax", cam.tagSlice());
}

test "zon-authored Camera without a tag keeps the default main slot" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    const e = game.createEntity();

    _ = Writer.addComponents(e, &game, .{ .Camera = .{ .zoom = 1.5 } }, null);

    const cam = game.ecs_backend.getComponent(e, Game.CameraComp) orelse
        return error.CameraComponentDropped;
    try testing.expectEqual(@as(f32, 1.5), cam.zoom);
    try testing.expectEqualStrings("main", cam.tagSlice());
}

test "zon-authored Image lands on the entity with its authored fields" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    const e = game.createEntity();

    _ = Writer.addComponents(e, &game, .{ .Image = .{ .name = "logo", .pivot = .bottom_left } }, null);

    const img = game.ecs_backend.getComponent(e, Game.ImageComp) orelse
        return error.ImageComponentDropped;
    try testing.expectEqualStrings("logo", img.name);
    try testing.expectEqual(engine.ImagePivot.bottom_left, img.pivot);
}

test "zon-authored Emitter lands on the entity and drives the particle tick" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    const e = game.createEntity();

    try testing.expect(!game.drive_particles);
    _ = Writer.addComponents(e, &game, .{ .Emitter = .{ .preset = .sparks } }, null);

    const em = game.ecs_backend.getComponent(e, Game.EmitterComp) orelse
        return error.EmitterComponentDropped;
    try testing.expectEqual(engine.EmitterPreset.sparks, em.preset);
    // Parity with the JSONC `applyEmitter`: authoring an emitter turns the
    // particle tick on by itself, otherwise the component lands inert.
    try testing.expect(game.drive_particles);
}

test "zon-authored Tilemap lands on the entity" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    const e = game.createEntity();

    _ = Writer.addComponents(e, &game, .{ .Tilemap = .{ .asset_name = "level_1" } }, null);

    const tm = game.ecs_backend.getComponent(e, Game.TilemapComp) orelse
        return error.TilemapComponentDropped;
    try testing.expectEqualStrings("level_1", tm.asset_name);
}

// ── Built-ins must not cost the existing dispatch anything ──────────────

test "Sprite and Shape still route through their renderer-registering adds" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const sprite_entity = game.createEntity();
    const sprite_vtype = Writer.addComponents(sprite_entity, &game, .{ .Sprite = .{ .sprite_name = "hero" } }, null);
    try testing.expectEqual(core.VisualType.sprite, sprite_vtype);
    try testing.expect(game.ecs_backend.getComponent(sprite_entity, Game.SpriteComp) != null);

    const shape_entity = game.createEntity();
    const shape_vtype = Writer.addComponents(shape_entity, &game, .{ .Shape = .{} }, null);
    try testing.expectEqual(core.VisualType.shape, shape_vtype);
    try testing.expect(game.ecs_backend.getComponent(shape_entity, Game.ShapeComp) != null);
}

test "a non-visual built-in leaves the entity visual type alone" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    const e = game.createEntity();

    const vtype = Writer.addComponents(e, &game, .{
        .Sprite = .{ .sprite_name = "hero" },
        .Emitter = .{ .preset = .smoke },
    }, null);

    try testing.expectEqual(core.VisualType.sprite, vtype);
    try testing.expect(game.ecs_backend.getComponent(e, Game.EmitterComp) != null);
}

// ── Registry precedence ─────────────────────────────────────────────────

test "a project-registered Camera shadows the engine built-in in .zon too" {
    var game = ShadowGame.init(testing.allocator);
    defer game.deinit();
    const e = game.createEntity();

    _ = ShadowWriter.addComponents(e, &game, .{ .Camera = .{ .rig = 7 } }, null);

    const project = game.ecs_backend.getComponent(e, ProjectCamera) orelse
        return error.ProjectCameraDropped;
    try testing.expectEqual(@as(u32, 7), project.rig);
    // ...and the built-in must NOT have been attached alongside it.
    try testing.expect(game.ecs_backend.getComponent(e, ShadowGame.CameraComp) == null);
}

// ── Prefab + scene-override merge path ──────────────────────────────────

test "scene overrides merge onto a prefab-authored built-in" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    const e = game.createEntity();

    _ = Writer.addMergedComponents(
        e,
        &game,
        .{ .Emitter = .{ .preset = .smoke } },
        .{ .Emitter = .{ .preset = .rain } },
        null,
    );

    const em = game.ecs_backend.getComponent(e, Game.EmitterComp) orelse
        return error.EmitterComponentDropped;
    try testing.expectEqual(engine.EmitterPreset.rain, em.preset);
}

test "a scene-only built-in not present in the prefab is still written" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    const e = game.createEntity();

    _ = Writer.addMergedComponents(
        e,
        &game,
        .{ .Sprite = .{ .sprite_name = "hero" } },
        .{ .Camera = .{ .zoom = 3 } },
        null,
    );

    const cam = game.ecs_backend.getComponent(e, Game.CameraComp) orelse
        return error.CameraComponentDropped;
    try testing.expectEqual(@as(f32, 3), cam.zoom);
}

test "a prefab-authored built-in with no scene override is still written" {
    var game = Game.init(testing.allocator);
    defer game.deinit();
    const e = game.createEntity();

    _ = Writer.addMergedComponents(
        e,
        &game,
        .{ .Image = .{ .name = "backdrop" } },
        .{},
        null,
    );

    const img = game.ecs_backend.getComponent(e, Game.ImageComp) orelse
        return error.ImageComponentDropped;
    try testing.expectEqualStrings("backdrop", img.name);
}

// ── The completeness gate itself ────────────────────────────────────────

test "the writer's built-in dispatch is complete for every Builtin tag" {
    // Forcing `builtin_dispatch_complete` instantiates `handlerFor` for
    // EVERY tag of `scene.builtins.Builtin`. That switch is exhaustive, so
    // a built-in added to the enum without a writer branch cannot compile —
    // which is the #881 guarantee this test names (verified by temporarily
    // adding a `Fake` tag: the build fails with "unhandled enumeration
    // value: 'Fake'" at `handlerFor`).
    try testing.expect(Writer.builtin_dispatch_complete);
    try testing.expect(ShadowWriter.builtin_dispatch_complete);
}

test "the built-in name set is the one source of truth both dispatch sites use" {
    try testing.expectEqual(@as(usize, 6), scene.builtins.names.len);
    inline for (scene.builtins.names) |n| try testing.expect(scene.builtins.has(n));
    try testing.expect(!scene.builtins.has("Position"));
}
