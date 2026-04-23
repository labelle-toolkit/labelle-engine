//! SpriteByField tick system tests.
//!
//! Covers:
//! - runtime component-name + field-name resolution via the
//!   ComponentRegistry inline-for;
//! - integer and enum field coercion to `i32`;
//! - `.self` vs `.parent` source;
//! - cache short-circuit (same-key tick doesn't call markVisualDirty);
//! - soft-fail on unknown component / unknown field / no-match.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const core = @import("labelle-core");

const SpriteByField = engine.SpriteByField;
const spriteByFieldTick = engine.spriteByFieldTick;

const game_mod = engine.game_mod;
const scene_mod = engine.scene_mod;
const ComponentRegistry = scene_mod.ComponentRegistry;

// Driving components the tests use. Register both so the tick's
// inline-for has two candidate branches to choose between on runtime
// name match (not just one).

const Level = struct {
    pub const save = core.Saveable(.saveable, @This(), .{});
    value: i32 = 0,
};

const Mood = enum { happy, sad, angry };
const Feelings = struct {
    pub const save = core.Saveable(.saveable, @This(), .{});
    mood: Mood = .happy,
};

const TestComponents = ComponentRegistry(.{
    .SpriteByField = SpriteByField,
    .Level = Level,
    .Feelings = Feelings,
});

const MockEcs = core.MockEcsBackend(u32);
const TestGame = game_mod.GameConfig(
    core.StubRender(MockEcs.Entity),
    MockEcs,
    engine.input_mod.StubInput,
    engine.audio_mod.StubAudio,
    engine.gui_mod.StubGui,
    void,
    core.StubLogSink,
    TestComponents,
    &.{},
    void,
);

const Sprite = TestGame.SpriteComp;

const plant_entries = [_]SpriteByField.Entry{
    .{ .key = 0, .sprite_name = null },                 // hide
    .{ .key = 1, .sprite_name = null },                 // hide
    .{ .key = 2, .sprite_name = "sapling_lvl1.png" },
    .{ .key = 3, .sprite_name = "sapling_lvl2.png" },
    .{ .key = 4, .sprite_name = "green_lvl1.png" },
    .{ .key = 5, .sprite_name = "green_lvl2.png" },
};

const mood_entries = [_]SpriteByField.Entry{
    .{ .key = 0, .sprite_name = "smile.png" },
    .{ .key = 1, .sprite_name = "frown.png" },
    .{ .key = 2, .sprite_name = "scowl.png" },
};

test "tick: integer field drives sprite_name via .self" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const entity = game.createEntity();
    game.active_world.ecs_backend.addComponent(entity, Sprite{ .sprite_name = "" });
    game.active_world.ecs_backend.addComponent(entity, Level{ .value = 3 });
    game.active_world.ecs_backend.addComponent(entity, SpriteByField{
        .component = "Level",
        .field = "value",
        .source = .self,
        .entries = &plant_entries,
    });

    spriteByFieldTick(&game, 0.016);

    const sprite = game.active_world.ecs_backend.getComponent(entity, Sprite).?;
    try testing.expectEqualStrings("sapling_lvl2.png", sprite.sprite_name);
}

test "tick: enum field drives sprite_name via @intFromEnum" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const entity = game.createEntity();
    game.active_world.ecs_backend.addComponent(entity, Sprite{ .sprite_name = "" });
    game.active_world.ecs_backend.addComponent(entity, Feelings{ .mood = .sad });
    game.active_world.ecs_backend.addComponent(entity, SpriteByField{
        .component = "Feelings",
        .field = "mood",
        .source = .self,
        .entries = &mood_entries,
    });

    spriteByFieldTick(&game, 0.016);

    const sprite = game.active_world.ecs_backend.getComponent(entity, Sprite).?;
    // @intFromEnum(.sad) == 1 → "frown.png"
    try testing.expectEqualStrings("frown.png", sprite.sprite_name);
}

test "tick: .parent source reads driving field off parent entity" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const parent = game.createEntity();
    game.active_world.ecs_backend.addComponent(parent, Level{ .value = 4 });

    const child = game.createEntity();
    game.active_world.ecs_backend.addComponent(child, Sprite{ .sprite_name = "" });
    game.setParent(child, parent, .{});
    game.active_world.ecs_backend.addComponent(child, SpriteByField{
        .component = "Level",
        .field = "value",
        .source = .parent,
        .entries = &plant_entries,
    });

    spriteByFieldTick(&game, 0.016);

    const sprite = game.active_world.ecs_backend.getComponent(child, Sprite).?;
    try testing.expectEqualStrings("green_lvl1.png", sprite.sprite_name);
}

test "tick: null sprite_name hides the sprite" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const entity = game.createEntity();
    game.active_world.ecs_backend.addComponent(entity, Sprite{
        .sprite_name = "previous.png",
        .visible = true,
    });
    game.active_world.ecs_backend.addComponent(entity, Level{ .value = 1 });
    game.active_world.ecs_backend.addComponent(entity, SpriteByField{
        .component = "Level",
        .field = "value",
        .source = .self,
        .entries = &plant_entries,
    });

    spriteByFieldTick(&game, 0.016);

    const sprite = game.active_world.ecs_backend.getComponent(entity, Sprite).?;
    // Key 1 in the table has null sprite_name → tick sets visible = false.
    // sprite_name is not overwritten (it's a "hide" action, not a "swap").
    try testing.expect(!sprite.visible);
    try testing.expectEqualStrings("previous.png", sprite.sprite_name);
}

test "tick: unknown key (.no_match) leaves the sprite alone" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const entity = game.createEntity();
    game.active_world.ecs_backend.addComponent(entity, Sprite{
        .sprite_name = "unchanged.png",
        .visible = true,
    });
    game.active_world.ecs_backend.addComponent(entity, Level{ .value = 42 }); // not in table
    game.active_world.ecs_backend.addComponent(entity, SpriteByField{
        .component = "Level",
        .field = "value",
        .source = .self,
        .entries = &plant_entries,
    });

    spriteByFieldTick(&game, 0.016);

    const sprite = game.active_world.ecs_backend.getComponent(entity, Sprite).?;
    try testing.expectEqualStrings("unchanged.png", sprite.sprite_name);
    try testing.expect(sprite.visible);
}

test "tick: unknown component name is a silent skip" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const entity = game.createEntity();
    game.active_world.ecs_backend.addComponent(entity, Sprite{ .sprite_name = "unchanged.png" });
    game.active_world.ecs_backend.addComponent(entity, SpriteByField{
        .component = "NonExistent",
        .field = "field",
        .source = .self,
        .entries = &plant_entries,
    });

    // No panic, no mutation.
    spriteByFieldTick(&game, 0.016);

    const sprite = game.active_world.ecs_backend.getComponent(entity, Sprite).?;
    try testing.expectEqualStrings("unchanged.png", sprite.sprite_name);
}

test "tick: unknown field name on a known component is a silent skip" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const entity = game.createEntity();
    game.active_world.ecs_backend.addComponent(entity, Sprite{ .sprite_name = "unchanged.png" });
    game.active_world.ecs_backend.addComponent(entity, Level{ .value = 2 });
    game.active_world.ecs_backend.addComponent(entity, SpriteByField{
        .component = "Level",
        .field = "nonexistent_field",
        .source = .self,
        .entries = &plant_entries,
    });

    spriteByFieldTick(&game, 0.016);

    const sprite = game.active_world.ecs_backend.getComponent(entity, Sprite).?;
    try testing.expectEqualStrings("unchanged.png", sprite.sprite_name);
}

test "tick: same-key idle ticks cache-short-circuit" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const entity = game.createEntity();
    game.active_world.ecs_backend.addComponent(entity, Sprite{ .sprite_name = "" });
    game.active_world.ecs_backend.addComponent(entity, Level{ .value = 2 });
    game.active_world.ecs_backend.addComponent(entity, SpriteByField{
        .component = "Level",
        .field = "value",
        .source = .self,
        .entries = &plant_entries,
    });

    // First tick: resolves + writes sprite_name.
    spriteByFieldTick(&game, 0.016);
    const sprite = game.active_world.ecs_backend.getComponent(entity, Sprite).?;
    try testing.expectEqualStrings("sapling_lvl1.png", sprite.sprite_name);

    // Manually corrupt sprite_name. A "properly cached" idle tick
    // should NOT overwrite — the level value didn't change, so no
    // update is needed. Regression guard: if the cache stops working,
    // this overwrite gets clobbered.
    sprite.sprite_name = "corrupted.png";

    spriteByFieldTick(&game, 0.016);
    try testing.expectEqualStrings("corrupted.png", sprite.sprite_name);
}

test "tick: changing the driving field re-resolves on the next tick" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const entity = game.createEntity();
    game.active_world.ecs_backend.addComponent(entity, Sprite{ .sprite_name = "" });
    game.active_world.ecs_backend.addComponent(entity, Level{ .value = 2 });
    game.active_world.ecs_backend.addComponent(entity, SpriteByField{
        .component = "Level",
        .field = "value",
        .source = .self,
        .entries = &plant_entries,
    });

    spriteByFieldTick(&game, 0.016);
    const sprite = game.active_world.ecs_backend.getComponent(entity, Sprite).?;
    try testing.expectEqualStrings("sapling_lvl1.png", sprite.sprite_name);

    // Level transitions 2 → 4: tick picks up the change.
    const level = game.active_world.ecs_backend.getComponent(entity, Level).?;
    level.value = 4;

    spriteByFieldTick(&game, 0.016);
    try testing.expectEqualStrings("green_lvl1.png", sprite.sprite_name);
}

test "tick: .parent with no parent is a silent skip" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const entity = game.createEntity();
    game.active_world.ecs_backend.addComponent(entity, Sprite{ .sprite_name = "unchanged.png" });
    // No parent attached.
    game.active_world.ecs_backend.addComponent(entity, SpriteByField{
        .component = "Level",
        .field = "value",
        .source = .parent,
        .entries = &plant_entries,
    });

    spriteByFieldTick(&game, 0.016);

    const sprite = game.active_world.ecs_backend.getComponent(entity, Sprite).?;
    try testing.expectEqualStrings("unchanged.png", sprite.sprite_name);
}
