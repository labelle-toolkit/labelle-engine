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

fn noSceneLoad(_: *Game) !void {}
const atlas_source =
    \\{"frames":{"a":{"frame":{"x":0,"y":0,"w":1,"h":1}},"b":{"frame":{"x":1,"y":0,"w":1,"h":1}},"c":{"frame":{"x":2,"y":0,"w":1,"h":1}}},"meta":{"size":{"w":3,"h":1}}}
;

test "no scene or empty manifest leaves asynchronous animations unvalidated and playing" {
    var game = Game.init(std.testing.allocator);
    defer game.deinit();
    try game.loadAnimationJsoncSource("prop", source);
    var anim = engine.SpriteAnimation{ .definition = "prop", .clip = "idle", .fps = 4 };
    try game.bindSpriteAnimation(&anim);
    const entity = game.createEntity();
    game.addComponent(entity, anim);
    game.validateSceneSpriteAnimations();
    const stored = game.ecs_backend.getComponent(entity, engine.SpriteAnimation).?;
    try std.testing.expect(!stored.definition_validated);
    try std.testing.expectEqual(@as(f32, 1), stored.speed);
    try game.scenes.put("main", .{ .loader_fn = noSceneLoad, .hooks = .{} });
    game.current_scene_name = try game.allocator.dupe(u8, "main");
    game.validateSceneSpriteAnimations();
    try std.testing.expect(!stored.definition_validated);
    try std.testing.expectEqual(@as(f32, 1), stored.speed);
    // Finishing an imperative load later makes explicit validation succeed.
    try game.atlas_manager.loadAtlasFromJsonContent("props", atlas_source, 7, null);
    try game.validateSpriteAnimation(stored);
}

test "pending metadata and atlases outside the active manifest do not validate" {
    var game = Game.init(std.testing.allocator);
    defer game.deinit();
    try game.loadAnimationJsoncSource("prop", source);
    var anim = engine.SpriteAnimation{ .definition = "prop", .clip = "idle", .fps = 4 };
    try game.bindSpriteAnimation(&anim);
    try game.atlas_manager.registerPendingAtlas("props", atlas_source, "png", ".png");
    try std.testing.expect(game.findSprite("a") != null); // metadata exists
    try std.testing.expectError(error.MissingAnimationFrame, game.validateSpriteAnimation(&anim));
    try game.atlas_manager.markPendingLoaded("props", 7, null);
    try game.validateSpriteAnimation(&anim);
    try game.scenes.put("main", .{ .loader_fn = noSceneLoad, .hooks = .{}, .assets = &.{"other"} });
    game.current_scene_name = try game.allocator.dupe(u8, "main");
    try std.testing.expectError(error.MissingAnimationFrame, game.validateSpriteAnimation(&anim));
    game.scenes.getPtr("main").?.assets = &.{"props"};
    try game.validateSpriteAnimation(&anim);
}

test "Game.tick synchronizes newly bound frame zero under both pause controls" {
    for ([_]bool{ false, true }) |time_scale_pause| {
        var game = Game.init(std.testing.allocator);
        defer game.deinit();
        try game.loadAnimationJsoncSource("prop", source);
        var anim = engine.SpriteAnimation{ .definition = "prop", .clip = "idle", .fps = 4 };
        try game.bindSpriteAnimation(&anim);
        // Even a pending accumulated interval must not be consumed on pause.
        anim.timer = 0.5;
        const entity = game.createEntity();
        game.addComponent(entity, anim);
        game.addComponent(entity, Game.SpriteComp{ .sprite_name = "placeholder" });
        game.setDriveSpriteAnimations(true);
        if (time_scale_pause) game.setTimeScale(0) else game.setSpriteAnimationsPaused(true);
        game.tick(0.25);
        const stored = game.ecs_backend.getComponent(entity, engine.SpriteAnimation).?;
        try std.testing.expectEqualStrings("a", game.ecs_backend.getComponent(entity, Game.SpriteComp).?.sprite_name);
        try std.testing.expectEqual(@as(u8, 0), stored.frame);
        try std.testing.expectEqual(@as(f32, 0.5), stored.timer);
        try std.testing.expect(!stored.definition_dirty);
    }
}
