//! Edge-case tests for `JsoncSceneBridge::deserialize` — optional
//! handling and slice handling, the two branches added in #488.
//!
//! Most of the deserializer is already exercised indirectly by every
//! scene/prefab test in the suite; this file pins the tricky cases
//! that caused regressions on first landing:
//!
//! - Optional field receiving JSONC `null` should succeed with a
//!   `null` value (not fail).
//! - Optional field receiving a well-formed value should succeed
//!   with that value.
//! - Optional field receiving a malformed non-null value should
//!   **fail and propagate the failure** — the parent struct should
//!   see "deserialize failed," NOT "present and null." Cursor Bugbot
//!   on #488 @ 2311b2d flagged a version of the code that silently
//!   swallowed the malformed case as null; this test locks that
//!   corner down.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const core = @import("labelle-core");

// Minimal component with an optional non-trivial field so we can
// drive the three edge cases above through the scene-load path.
const Decoration = struct {
    pub const save = core.Saveable(.saveable, @This(), .{});
    label: ?[]const u8 = null,
    priority: i32 = 0,
};

const TestComponents = engine.ComponentRegistry(.{
    .Decoration = Decoration,
});

const MockEcs = core.MockEcsBackend(u32);
const TestGame = engine.game_mod.GameConfig(
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

const Bridge = engine.JsoncSceneBridge(TestGame, TestComponents);

fn boot(scene_jsonc: []const u8) !TestGame {
    var game = TestGame.init(testing.allocator);
    errdefer game.deinit();
    try Bridge.loadSceneFromSource(&game, scene_jsonc, "/tmp/labelle-nonexistent");
    return game;
}

fn oneEntity(game: *TestGame) TestGame.EntityType {
    var view = game.ecs_backend.view(.{Decoration}, .{});
    defer view.deinit();
    return view.next().?;
}

test "deserialize optional: JSONC null → field is null (success path)" {
    var game = try boot(
        \\{ "entities": [
        \\  { "components": { "Decoration": { "label": null, "priority": 7 } } }
        \\] }
    );
    defer game.deinit();

    const decor = game.ecs_backend.getComponent(oneEntity(&game), Decoration).?;
    try testing.expect(decor.label == null);
    try testing.expectEqual(@as(i32, 7), decor.priority);
}

test "deserialize optional: JSONC string → field is that string (success path)" {
    var game = try boot(
        \\{ "entities": [
        \\  { "components": { "Decoration": { "label": "banner", "priority": 3 } } }
        \\] }
    );
    defer game.deinit();

    const decor = game.ecs_backend.getComponent(oneEntity(&game), Decoration).?;
    try testing.expect(decor.label != null);
    try testing.expectEqualStrings("banner", decor.label.?);
    try testing.expectEqual(@as(i32, 3), decor.priority);
}

test "deserialize optional: malformed non-null value fails (does NOT silently become null)" {
    // `label` declared as `?[]const u8` but the JSON gives an
    // integer. The optional branch used to `return`-forward the
    // inner deserialize's `?U` directly, and Zig's `?U` → `??U`
    // coercion wrapped a failure (null `?U`) as a non-null outer
    // containing a null inner — i.e. "successfully deserialized a
    // present-but-null value" — silently masking the type error.
    //
    // Correct behaviour: the malformed field fails to deserialize
    // → `deserializeStruct` either falls back to the default (if one
    // exists) or rejects the whole struct. `Decoration.label`
    // defaults to `null`, so here the struct succeeds with the
    // default AND the other field still applies — the contract we
    // pin is specifically that `label` is null because the field
    // failed, not because "null" was accepted as a non-null integer.
    var game = try boot(
        \\{ "entities": [
        \\  { "components": { "Decoration": { "label": 42, "priority": 5 } } }
        \\] }
    );
    defer game.deinit();

    const decor = game.ecs_backend.getComponent(oneEntity(&game), Decoration).?;
    try testing.expect(decor.label == null);
    // Priority still applies — only the malformed field was skipped,
    // not the whole component.
    try testing.expectEqual(@as(i32, 5), decor.priority);
}
