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

const MarkerEvents = union(enum) {
    engine__anim_marker: engine.Events.anim_marker,
    engine__anim_complete: engine.Events.anim_complete,
    engine__anim_loop: engine.Events.anim_loop,
};
const MarkerReceiver = struct {
    ctx: engine.HookContext = .{},
    replace_on_first: bool = false,
    hits: [1024]engine.Events.anim_marker = undefined,
    count: usize = 0,
    pub fn engine__anim_marker(self: *@This(), event: engine.Events.anim_marker) void {
        self.hits[self.count] = event;
        self.count += 1;
        if (self.replace_on_first) {
            self.replace_on_first = false;
            const game = self.ctx.gameAs(MarkerGame);
            game.resetEcsBackend();
            _ = markerEntity(game) catch @panic("test replacement failed");
        }
    }
};
const MarkerPayload = core.MergeHookPayloads(.{ engine.HookPayload(u32), MarkerEvents });
const MarkerHooks = core.MergeHooks(MarkerPayload, .{*MarkerReceiver});
const MarkerGame = engine.GameConfig(core.StubRender(Ecs.Entity), Ecs, engine.StubInput, engine.StubAudio, engine.StubVideo, engine.StubGui, *MarkerHooks, core.StubLogSink, Components, &.{}, MarkerEvents);
const marked_source = "{\"version\":1,\"clips\":{\"walk\":{\"frames\":[\"a\",\"b\",\"c\"],\"markers\":[{\"name\":\"start\",\"frame\":0},{\"name\":\"footstep\",\"frame\":1}]}}}";

fn markerEntity(game: *MarkerGame) !u32 {
    const e = game.createEntity();
    var anim = engine.SpriteAnimation{ .definition = "prop", .clip = "walk", .fps = 4 };
    try game.bindSpriteAnimation(&anim);
    game.addComponent(e, anim);
    game.addComponent(e, MarkerGame.SpriteComp{ .sprite_name = "old" });
    return e;
}

test "named markers deliver typed payloads at drain with independent playback identities" {
    var game = MarkerGame.init(std.testing.allocator);
    defer game.deinit();
    var receiver: MarkerReceiver = .{};
    var hooks = MarkerHooks{ .receivers = .{&receiver} };
    game.setHooks(&hooks);
    try game.loadAnimationJsoncSource("prop", marked_source);
    const a = try markerEntity(&game);
    const b = try markerEntity(&game);
    game.ecs_backend.getComponent(b, engine.SpriteAnimation).?.speed = 0;
    engine.spriteAnimationTick(&game, 0.5);
    try std.testing.expectEqual(@as(usize, 0), receiver.count);
    game.dispatchEvents();
    try std.testing.expectEqual(@as(usize, 3), receiver.count);
    var a_hits: usize = 0;
    for (receiver.hits[0..receiver.count]) |hit| {
        try std.testing.expect(game.isAnimationMarkerTargetAlive(hit));
        try std.testing.expectEqualStrings("prop", hit.definition);
        try std.testing.expectEqualStrings("walk", hit.clip);
        if (hit.entity == a) a_hits += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), a_hits);
    const first = game.ecs_backend.getComponent(a, engine.SpriteAnimation).?;
    const second = game.ecs_backend.getComponent(b, engine.SpriteAnimation).?;
    try std.testing.expect(first.marker_playback_id != second.marker_playback_id);
    try std.testing.expect(first.marker_target_id != second.marker_target_id);
    try std.testing.expectEqual(@as(u8, 0), second.frame);
}

test "queued markers cannot target replacement entities after ECS reset" {
    var game = MarkerGame.init(std.testing.allocator);
    defer game.deinit();
    var receiver: MarkerReceiver = .{};
    var hooks = MarkerHooks{ .receivers = .{&receiver} };
    game.setHooks(&hooks);
    try game.loadAnimationJsoncSource("prop", marked_source);
    _ = try markerEntity(&game);
    engine.spriteAnimationTick(&game, 0.25);
    const old = game.event_buffer.items[0].engine__anim_marker;
    game.resetEcsBackend();
    _ = try markerEntity(&game);
    try std.testing.expect(!game.isAnimationMarkerTargetAlive(old));
    game.dispatchEvents();
    try std.testing.expectEqual(@as(usize, 0), receiver.count);
}

test "rebind keeps crossed markers original playback identity and owned names" {
    var game = MarkerGame.init(std.testing.allocator);
    defer game.deinit();
    var receiver: MarkerReceiver = .{};
    var hooks = MarkerHooks{ .receivers = .{&receiver} };
    game.setHooks(&hooks);
    try game.loadAnimationJsoncSource("prop", marked_source);
    const e = try markerEntity(&game);
    engine.spriteAnimationTick(&game, 0.25);
    const anim = game.ecs_backend.getComponent(e, engine.SpriteAnimation).?;
    const old_playback = anim.marker_playback_id;
    try game.selectSpriteAnimation(anim, "prop", "walk");
    try std.testing.expect(anim.marker_playback_id != old_playback);
    game.dispatchEvents();
    try std.testing.expectEqual(@as(usize, 2), receiver.count);
    for (receiver.hits[0..receiver.count]) |hit| {
        try std.testing.expectEqual(old_playback, hit.playback_id);
        try std.testing.expect(game.isAnimationMarkerTargetAlive(hit));
    }
}

test "failed real event enqueue retains marker until a later tick and drain" {
    var game = MarkerGame.init(std.testing.allocator);
    defer game.deinit();
    var receiver: MarkerReceiver = .{};
    var hooks = MarkerHooks{ .receivers = .{&receiver} };
    game.setHooks(&hooks);
    try game.loadAnimationJsoncSource("prop", marked_source);
    const e = try markerEntity(&game);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    game.allocator = failing.allocator();
    engine.spriteAnimationTick(&game, 0.25);
    game.allocator = std.testing.allocator;
    const anim = game.ecs_backend.getComponent(e, engine.SpriteAnimation).?;
    try std.testing.expect(anim.marker_stalled);
    try std.testing.expectEqual(@as(usize, 0), game.event_buffer.items.len);
    engine.spriteAnimationTick(&game, 0);
    game.dispatchEvents();
    try std.testing.expectEqual(@as(usize, 1), receiver.count);
    try std.testing.expectEqual(@as(u64, 0), receiver.hits[0].sequence);
    try std.testing.expectEqualStrings("start", receiver.hits[0].marker);
}

test "clip replacement refuses undelivered crossings without mutating playback" {
    var game = MarkerGame.init(std.testing.allocator);
    defer game.deinit();
    try game.loadAnimationJsoncSource("prop", marked_source);
    const e = try markerEntity(&game);
    const anim = game.ecs_backend.getComponent(e, engine.SpriteAnimation).?;
    const previous_id = anim.marker_playback_id;
    try std.testing.expectError(error.PendingAnimationMarkers, game.selectSpriteAnimation(anim, "missing", "walk"));
    try std.testing.expectEqual(previous_id, anim.marker_playback_id);
    try std.testing.expectEqualStrings("prop", anim.definition);
    engine.spriteAnimationTick(&game, 0);
    try std.testing.expectError(error.UnknownAnimationDefinition, game.selectSpriteAnimation(anim, "missing", "walk"));
    try std.testing.expectEqual(previous_id, anim.marker_playback_id);
    try game.selectSpriteAnimation(anim, "prop", "walk");
    try std.testing.expect(anim.marker_playback_id != previous_id);
}

test "pause freezes deferred beats and resumes at current speed" {
    var game = MarkerGame.init(std.testing.allocator);
    defer game.deinit();
    try game.loadAnimationJsoncSource("prop", marked_source);
    const e = try markerEntity(&game);
    engine.spriteAnimationTick(&game, 100);
    const anim = game.ecs_backend.getComponent(e, engine.SpriteAnimation).?;
    try std.testing.expect(anim.marker_cursor.steps > 0);
    try std.testing.expect(anim.marker_stalled);
    const frame = anim.frame;
    const steps = anim.marker_cursor.steps;
    anim.speed = 0;
    engine.spriteAnimationTick(&game, 1);
    try std.testing.expectEqual(frame, anim.frame);
    try std.testing.expectEqual(steps, anim.marker_cursor.steps);
    anim.speed = 0.5;
    engine.spriteAnimationTick(&game, 1);
    try std.testing.expect(anim.marker_cursor.steps < steps);
}

test "a hook can reset the world and later queued markers cannot hit its replacement" {
    var game = MarkerGame.init(std.testing.allocator);
    defer game.deinit();
    var receiver = MarkerReceiver{ .replace_on_first = true };
    var hooks = MarkerHooks{ .receivers = .{&receiver} };
    game.setHooks(&hooks);
    try game.loadAnimationJsoncSource("prop", marked_source);
    _ = try markerEntity(&game);
    engine.spriteAnimationTick(&game, 0.5);
    game.dispatchEvents();
    try std.testing.expectEqual(@as(usize, 1), receiver.count);
    try std.testing.expectEqualStrings("start", receiver.hits[0].marker);
    try std.testing.expect(!game.isAnimationMarkerTargetAlive(receiver.hits[0]));
}

test "unused marker metadata retains eventless large delta playback and selection" {
    var game = Game.init(std.testing.allocator);
    defer game.deinit();
    try game.loadAnimationJsoncSource("prop", marked_source);
    const e = game.createEntity();
    var anim = engine.SpriteAnimation{ .definition = "prop", .clip = "walk", .fps = 4 };
    try game.bindSpriteAnimation(&anim);
    var plain = engine.SpriteAnimation{ .frames = anim.frames, .fps = 4 };
    game.addComponent(e, anim);
    game.addComponent(e, Game.SpriteComp{ .sprite_name = "old" });
    _ = plain.advance(100);
    engine.spriteAnimationTick(&game, 100);
    const actual = game.ecs_backend.getComponent(e, engine.SpriteAnimation).?;
    try std.testing.expectEqual(plain.frame, actual.frame);
    try std.testing.expectEqual(@as(u64, 0), actual.marker_cursor.steps);
    try game.selectSpriteAnimation(actual, "prop", "walk");
}

test "marked player retains elapsed seconds across fps changes and pause" {
    var game = MarkerGame.init(std.testing.allocator);
    defer game.deinit();
    try game.loadAnimationJsoncSource("prop", marked_source);
    const e = try markerEntity(&game);
    engine.spriteAnimationTick(&game, 0.125);
    const anim = game.ecs_backend.getComponent(e, engine.SpriteAnimation).?;
    anim.fps = 0;
    engine.spriteAnimationTick(&game, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 0.125), anim.timer, 0.000001);
    anim.fps = 8;
    engine.spriteAnimationTick(&game, 0.001);
    try std.testing.expectEqual(@as(u8, 1), anim.frame);
    try std.testing.expectApproxEqAbs(@as(f32, 0.001), anim.timer, 0.000001);
}

test "prefab refresh preserves pending crossings and queued target identity" {
    var game = MarkerGame.init(std.testing.allocator);
    defer game.deinit();
    var receiver: MarkerReceiver = .{};
    var hooks = MarkerHooks{ .receivers = .{&receiver} };
    game.setHooks(&hooks);
    try game.loadAnimationJsoncSource("prop", marked_source);
    const B = engine.JsoncSceneBridge(MarkerGame, Components);
    const prefab =
        \\{"components":{"Sprite":{"sprite_name":"a"},"SpriteAnimation":{"definition":"prop","clip":"walk","fps":4}}}
    ;
    try B.addEmbeddedPrefab(&game, "propeller", prefab, "prefabs");
    try B.loadSceneFromSource(&game, "{\"children\":[]}", "prefabs");
    const e = game.spawnPrefab("propeller", .{ .x = 0, .y = 0 }).?;
    engine.spriteAnimationTick(&game, 100);
    const before = game.ecs_backend.getComponent(e, engine.SpriteAnimation).?.*;
    try std.testing.expect(before.marker_cursor.steps > 0);
    try game.reloadPrefabSource("propeller", prefab);
    const after = game.ecs_backend.getComponent(e, engine.SpriteAnimation).?;
    try std.testing.expectEqual(before.marker_cursor.steps, after.marker_cursor.steps);
    try std.testing.expectEqual(before.marker_playback_id, after.marker_playback_id);
    while (after.marker_cursor.pending()) {
        game.dispatchEvents();
        engine.spriteAnimationTick(&game, 0.00001);
    }
    // Retrying a now-unblocked refresh preserves already queued targets.
    const queued_playback = after.marker_playback_id;
    try game.reloadPrefabSource("propeller", prefab);
    try std.testing.expectEqual(before.marker_target_id, after.marker_target_id);
    try std.testing.expect(queued_playback != after.marker_playback_id);
    game.dispatchEvents();
    try std.testing.expectEqual(@as(usize, 268), receiver.count);
}

test "named lifecycle events saturate wide entity IDs" {
    const WideGame = struct {
        const Payload = union(enum) {
            engine__anim_complete: engine.Events.anim_complete,
            engine__anim_loop: engine.Events.anim_loop,
        };
        const Log = struct {
            pub fn warn(_: @This(), comptime _: []const u8, _: anytype) void {}
        };
        log: Log = .{},
        count: usize = 0,
        id: u32 = 0,
        pub fn nextAnimationIdentity(_: *@This()) u64 {
            return 1;
        }
        pub fn engineEventWanted(comptime name: []const u8) bool {
            return !std.mem.eql(u8, name, "engine__anim_marker");
        }
        pub fn tryEmit(self: *@This(), event: Payload) !void {
            self.id = switch (event) {
                inline else => |value| value.entity,
            };
            self.count += 1;
        }
    };
    inline for (.{ animation.BoundaryMode.once, animation.BoundaryMode.loop }) |mode| {
        var game: WideGame = .{};
        var anim = engine.SpriteAnimation{
            .frames = &.{ "a", "b" },
            .fps = 4,
            .mode = mode,
            .markers = &.{.{ .name = "start", .frame = 0 }},
        };
        _ = engine.advanceNamedAnimation(&game, std.math.maxInt(u64), &anim, 0.5);
        try std.testing.expectEqual(@as(usize, 1), game.count);
        try std.testing.expectEqual(std.math.maxInt(u32), game.id);
    }
}
