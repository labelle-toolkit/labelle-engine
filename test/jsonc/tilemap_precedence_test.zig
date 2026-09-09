//! C2 regression — a project-registered component named `Tilemap` must
//! WIN over the engine built-in `Tilemap` in the scene loader.
//!
//! Before the fix, the built-in `Tilemap` branch in `component_apply` ran
//! before the registry dispatch and returned unconditionally, so a
//! registered `Tilemap` was silently shadowed: its scene JSON deserialized
//! as an empty engine tilemap (because `TilemapComp.asset_name` defaults to
//! `""`) and the registered component never loaded — silent data loss.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const core = @import("labelle-core");

/// A project component that happens to be named `Tilemap` (distinct shape
/// from the engine built-in, which only has `asset_name`).
const Tilemap = struct {
    pub const save = core.Saveable(.saveable, @This(), .{});
    rows: i32 = 0,
    cols: i32 = 0,
};

const TestComponents = engine.ComponentRegistry(.{
    .Tilemap = Tilemap,
});

const MockEcs = core.MockEcsBackend(u32);
const TestGame = engine.game_mod.GameConfig(
    core.StubRender(MockEcs.Entity),
    MockEcs,
    engine.input_mod.StubInput,
    engine.audio_mod.StubAudio,
    engine.StubVideo,
    engine.gui_mod.StubGui,
    void,
    core.StubLogSink,
    TestComponents,
    &.{},
    void,
);

const Bridge = engine.JsoncSceneBridge(TestGame, TestComponents);

test "a registered component named Tilemap wins over the engine built-in" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try Bridge.loadSceneFromSource(&game,
        \\{ "children": [
        \\  { "components": { "Tilemap": { "rows": 4, "cols": 7 } } }
        \\] }
    , "/tmp/labelle-nonexistent");

    var view = game.ecs_backend.view(.{Tilemap}, .{});
    defer view.deinit();
    const ent = view.next().?;

    // The REGISTERED component loaded with its real field values — not the
    // engine built-in (which would have swallowed the block as an empty
    // `asset_name` tilemap and left this component absent).
    const tm = game.ecs_backend.getComponent(ent, Tilemap).?;
    try testing.expectEqual(@as(i32, 4), tm.rows);
    try testing.expectEqual(@as(i32, 7), tm.cols);

    // And the engine built-in tilemap was NOT attached to the entity.
    try testing.expect(game.getComponent(ent, TestGame.TilemapComp) == null);
}
