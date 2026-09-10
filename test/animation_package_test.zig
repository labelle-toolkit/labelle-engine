const std = @import("std");
const animation = @import("animation");
const engine = @import("engine");

test "shared JSONC definition drives two independent existing SpriteAnimation players" {
    var definition = try animation.Definition.parse(std.testing.allocator,
        \\{"version":1,"clips":{"walk":{"frames_pattern":"walk_{frame:04}.png","from":1,"to":3}}}
    );
    defer definition.deinit();
    const frames = definition.find("walk").?.frames;
    var first = engine.SpriteAnimation{ .frames = frames, .fps = 4, .mode = .loop };
    var second = engine.SpriteAnimation{ .frames = frames, .fps = 4, .mode = .loop };
    _ = first.advance(0.25);
    try std.testing.expectEqualStrings("walk_0002.png", first.currentSprite().?);
    try std.testing.expectEqualStrings("walk_0001.png", second.currentSprite().?);
    _ = second.advance(0.5);
    try std.testing.expectEqualStrings("walk_0003.png", second.currentSprite().?);
    _ = first.advance(0.5);
    try std.testing.expectEqualStrings("walk_0001.png", first.currentSprite().?);
}

const core = @import("labelle-core");
const Components = engine.ComponentRegistry(.{ .SpriteAnimation = engine.SpriteAnimation });
const Ecs = core.MockEcsBackend(u32);
const Game = engine.game_mod.GameConfig(core.StubRender(Ecs.Entity), Ecs, engine.input_mod.StubInput, engine.audio_mod.StubAudio, engine.StubVideo, engine.gui_mod.StubGui, void, core.StubLogSink, Components, &.{}, void);
const Bridge = engine.JsoncSceneBridge(Game, Components);
const source = "{\"version\":1,\"clips\":{\"idle\":{\"frames\":[\"a\",\"b\",\"c\"]}}}";

test "JSONC scene binding shares owned frames, independent players, scene reset rebinds" {
    var game = Game.init(std.testing.allocator);
    defer game.deinit();
    try game.loadAnimationJsoncSource("animations/prop.jsonc", source);
    const scene =
        \\{"children":[
        \\{"Sprite": {"sprite_name":"old"}, "SpriteAnimation":{"definition":"animations/prop.jsonc","clip":"idle","fps":4}},
        \\{"Sprite": {"sprite_name":"old"}, "SpriteAnimation":{"definition":"animations/prop.jsonc","clip":"idle","fps":2}}
        \\]}
    ;
    try Bridge.loadSceneFromSource(&game, scene, ".");
    var view = game.ecs_backend.view(.{engine.SpriteAnimation}, .{});
    const a = view.next().?;
    const b = view.next().?;
    view.deinit();
    const first = game.ecs_backend.getComponent(a, engine.SpriteAnimation).?;
    const second = game.ecs_backend.getComponent(b, engine.SpriteAnimation).?;
    try std.testing.expect(first.frames.ptr == second.frames.ptr);
    engine.spriteAnimationTick(&game, 0);
    try std.testing.expectEqualStrings("a", game.ecs_backend.getComponent(a, Game.SpriteComp).?.sprite_name);
    engine.spriteAnimationTick(&game, 0.25);
    try std.testing.expect(first.frame != second.frame);
    game.resetEcsBackend();
    try Bridge.loadSceneFromSource(&game, scene, ".");
    var again = game.ecs_backend.view(.{engine.SpriteAnimation}, .{});
    defer again.deinit();
    var count: usize = 0;
    while (again.next()) |e| {
        const anim = game.ecs_backend.getComponent(e, engine.SpriteAnimation).?;
        try std.testing.expectEqual(@as(u8, 0), anim.frame);
        try std.testing.expectEqualStrings("a", anim.currentSprite().?);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "binding rejects missing names and ambiguous inline frames" {
    var game = Game.init(std.testing.allocator);
    defer game.deinit();
    try game.loadAnimationJsoncSource("prop", source);
    var anim = engine.SpriteAnimation{ .definition = "missing", .clip = "idle", .fps = 4 };
    try std.testing.expectError(error.UnknownAnimationDefinition, game.bindSpriteAnimation(&anim));
    anim.definition = "prop";
    anim.clip = "typo";
    try std.testing.expectError(error.UnknownAnimationClip, game.bindSpriteAnimation(&anim));
    anim.clip = "idle";
    anim.frames = &.{"inline"};
    try std.testing.expectError(error.AmbiguousAnimationFrames, game.bindSpriteAnimation(&anim));
}

test "library failures leave existing borrowed definitions intact" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, libraryLifecycle, .{});
}

fn libraryLifecycle(allocator: std.mem.Allocator) !void {
    var library = animation.Library.init(allocator);
    defer library.deinit();
    try library.load("prop", source);
    const old = library.get("prop").?;
    try std.testing.expectError(error.DuplicateAnimationDefinition, library.load("prop", source));
    try library.load("other", source);
    try std.testing.expect(old == library.get("prop").?);
    try std.testing.expectEqualStrings("a", old.find("idle").?.frames[0]);
}

test "missing resident atlas frames are reported by explicit validation" {
    var game = Game.init(std.testing.allocator);
    defer game.deinit();
    try game.loadAnimationJsoncSource("prop", source);
    var anim = engine.SpriteAnimation{ .definition = "prop", .clip = "idle", .fps = 4 };
    try game.bindSpriteAnimation(&anim);
    try std.testing.expectError(error.MissingAnimationFrame, game.validateSpriteAnimation(&anim));
}
