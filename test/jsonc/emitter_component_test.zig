//! `Emitter` component (#750) — scene-loader coverage.
//!
//! Proves:
//!   1. A scene entity with an `"Emitter"` block parses into the engine
//!      built-in `Emitter` component (both the `preset` selector form and
//!      the inline `config` form), and loading one flips `drive_particles`
//!      on so scene-authored emitters run without a manual opt-in.
//!   2. Built-in precedence: a project-registered component named `Emitter`
//!      wins over the engine built-in (mirrors the `Tilemap` / `Camera` /
//!      `Image` precedence contract in `component_apply.zig`).

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const core = @import("labelle-core");

const MockEcs = core.MockEcsBackend(u32);

fn Game(comptime Components: type) type {
    return engine.game_mod.GameConfig(
        core.StubRender(MockEcs.Entity),
        MockEcs,
        engine.input_mod.StubInput,
        engine.audio_mod.StubAudio,
        engine.StubVideo,
        engine.gui_mod.StubGui,
        void,
        core.StubLogSink,
        Components,
        &.{},
        void,
    );
}

// No project component named `Emitter` — the engine built-in is active.
const BuiltinComponents = engine.ComponentRegistry(.{});
const BuiltinGame = Game(BuiltinComponents);
const BuiltinBridge = engine.JsoncSceneBridge(BuiltinGame, BuiltinComponents);

test "Emitter: a preset block parses into the built-in and enables drive_particles" {
    var game = BuiltinGame.init(testing.allocator);
    defer game.deinit();

    try testing.expect(!game.drive_particles);

    try BuiltinBridge.loadSceneFromSource(&game,
        \\{ "children": [
        \\  { "components": { "Emitter": { "preset": "smoke" } } }
        \\] }
    , "/tmp/labelle-nonexistent");

    var view = game.ecs_backend.view(.{engine.Emitter}, .{});
    defer view.deinit();
    const ent = view.next().?;

    const em = game.ecs_backend.getComponent(ent, engine.Emitter).?;
    try testing.expectEqual(engine.EmitterPreset.smoke, em.preset);
    // Loading an emitter auto-enables the engine particle phase.
    try testing.expect(game.drive_particles);
}

test "Emitter: an inline config block parses its fields" {
    var game = BuiltinGame.init(testing.allocator);
    defer game.deinit();

    try BuiltinBridge.loadSceneFromSource(&game,
        \\{ "children": [
        \\  { "components": { "Emitter": { "config": {
        \\      "rate": 42,
        \\      "lifetime": 1.5,
        \\      "max_particles": 200
        \\  } } } }
        \\] }
    , "/tmp/labelle-nonexistent");

    var view = game.ecs_backend.view(.{engine.Emitter}, .{});
    defer view.deinit();
    const ent = view.next().?;

    const em = game.ecs_backend.getComponent(ent, engine.Emitter).?;
    try testing.expectEqual(engine.EmitterPreset.none, em.preset);
    try testing.expectEqual(@as(f32, 42), em.config.rate);
    try testing.expectEqual(@as(f32, 1.5), em.config.lifetime);
    try testing.expectEqual(@as(u32, 200), em.config.max_particles);
    // resolvedConfig should surface the inline config unchanged.
    try testing.expectEqual(@as(f32, 42), em.resolvedConfig().rate);
}

// ---------------------------------------------------------------------
// Precedence — a project-registered `Emitter` wins over the built-in.
// ---------------------------------------------------------------------

const ProjectEmitter = struct {
    pub const save = core.Saveable(.saveable, @This(), .{});
    power: i32 = 0,
};

const OverrideComponents = engine.ComponentRegistry(.{
    .Emitter = ProjectEmitter,
});
const OverrideGame = Game(OverrideComponents);
const OverrideBridge = engine.JsoncSceneBridge(OverrideGame, OverrideComponents);

test "Emitter: a registered component named Emitter wins over the engine built-in" {
    var game = OverrideGame.init(testing.allocator);
    defer game.deinit();

    try OverrideBridge.loadSceneFromSource(&game,
        \\{ "children": [
        \\  { "components": { "Emitter": { "power": 7 } } }
        \\] }
    , "/tmp/labelle-nonexistent");

    var view = game.ecs_backend.view(.{ProjectEmitter}, .{});
    defer view.deinit();
    const ent = view.next().?;
    const pe = game.ecs_backend.getComponent(ent, ProjectEmitter).?;
    try testing.expectEqual(@as(i32, 7), pe.power);

    // The built-in path must not fire: drive_particles stays off, and the
    // engine built-in Emitter is not attached.
    try testing.expect(!game.drive_particles);
    try testing.expect(game.getComponent(ent, engine.Emitter) == null);
}
