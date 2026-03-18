const std = @import("std");
const testing = std.testing;

const engine = @import("engine");
const Game = engine.Game;
const GameConfig = engine.GameConfig;
const GameWith = engine.GameWith;
const StubRender = engine.StubRender;
const MockEcsBackend = engine.MockEcsBackend;
const StubInput = engine.StubInput;
const StubAudio = engine.StubAudio;
const StubGui = engine.StubGui;
const StubLogSink = engine.StubLogSink;
const InputInterface = engine.InputInterface;
const AudioInterface = engine.AudioInterface;
const GuiInterface = engine.GuiInterface;
const ParentComponent = engine.ParentComponent;

test "Game: full lifecycle with StubRender" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const entity = game.createEntity();
    game.addSprite(entity, .{ .sprite_name = "player" });
    game.setPosition(entity, .{ .x = 100, .y = 200 });

    game.tick(0.016);
    game.render();

    try testing.expectEqual(1, game.entityCount());
}

test "GameConfig: RenderImpl slot is parameterized" {
    const TestRenderer = StubRender(u32);
    const CustomGame = GameConfig(
        TestRenderer,
        MockEcsBackend(u32),
        StubInput,
        StubAudio,
        StubGui,
        void,
    );

    var game = CustomGame.init(testing.allocator);
    defer game.deinit();

    const entity = game.createEntity();
    game.addShape(entity, .{
        .shape = .{ .rectangle = .{ .width = 50, .height = 50 } },
        .color = .{ .r = 255, .g = 0, .b = 0, .a = 255 },
    });
    game.setPosition(entity, .{ .x = 200, .y = 300 });

    game.tick(0.016);
    game.render();

    try testing.expectEqual(1, game.entityCount());
}

test "GameWith(Hooks): lifecycle hooks fire" {
    const MyHooks = struct {
        entity_count: u32 = 0,
        frame_count: u32 = 0,

        pub fn entity_created(self: *@This(), _: anytype) void {
            self.entity_count += 1;
        }
        pub fn frame_start(self: *@This(), _: anytype) void {
            self.frame_count += 1;
        }
    };

    var hooks = MyHooks{};
    var game = GameWith(*MyHooks).init(testing.allocator);
    defer game.deinit();
    game.setHooks(&hooks);

    _ = game.createEntity();
    _ = game.createEntity();
    game.tick(0.016);

    try testing.expectEqual(2, hooks.entity_count);
    try testing.expectEqual(1, hooks.frame_count);
}

test "InputInterface(StubInput) compiles" {
    const InputI = InputInterface(StubInput);
    try testing.expect(!InputI.isKeyDown(0));
    try testing.expect(!InputI.isKeyPressed(0));
    try testing.expectEqual(0.0, InputI.getMouseX());
}

test "AudioInterface(StubAudio) compiles" {
    const AudioI = AudioInterface(StubAudio);
    AudioI.playSound(0);
    AudioI.stopSound(0);
    AudioI.setVolume(0.5);
}

test "GuiInterface(StubGui) compiles" {
    const GuiI = GuiInterface(StubGui);
    GuiI.begin();
    GuiI.end();
    try testing.expect(!GuiI.wantsMouse());
    try testing.expect(!GuiI.wantsKeyboard());
}

test "Game: GUI forwarding methods work" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    game.guiBegin();
    game.guiEnd();
    try testing.expect(!game.guiWantsMouse());
    try testing.expect(!game.guiWantsKeyboard());
}

test "Game: scene management" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const loadTestScene = struct {
        fn load(g: *Game) anyerror!void {
            const e = g.createEntity();
            g.addSprite(e, .{ .sprite_name = "test" });
            g.setPosition(e, .{ .x = 50, .y = 50 });
        }
    }.load;

    game.registerSceneSimple("test", loadTestScene);
    try game.setScene("test");

    try testing.expectEqualStrings("test", game.getCurrentSceneName().?);
    try testing.expectEqual(1, game.entityCount());
}

test "Game: hierarchy parent/child" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const parent = game.createEntity();
    game.setPosition(parent, .{ .x = 100, .y = 100 });
    game.addSprite(parent, .{ .sprite_name = "parent" });

    const child = game.createEntity();
    game.setPosition(child, .{ .x = 10, .y = 10 });
    game.addSprite(child, .{ .sprite_name = "child" });
    game.setParent(child, parent, .{});

    game.tick(0.016);
    game.render();

    try testing.expect(game.hasComponent(child, ParentComponent(u32)));
    game.removeParent(child);
    try testing.expect(!game.hasComponent(child, ParentComponent(u32)));
}

test "Game: quit sets running to false" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    try testing.expect(game.isRunning());
    game.quit();
    try testing.expect(!game.isRunning());
}

test "Game: gizmo enable/disable" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    try testing.expect(game.isGizmosEnabled());
    game.setGizmosEnabled(false);
    try testing.expect(!game.isGizmosEnabled());
    game.setGizmosEnabled(true);
    try testing.expect(game.isGizmosEnabled());
}

test "Game: generic component access" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const Tag = struct { label: u32 };
    const e = game.createEntity();
    game.addComponent(e, Tag{ .label = 42 });

    const tag = game.getComponent(e, Tag);
    try testing.expect(tag != null);
    try testing.expectEqual(42, tag.?.label);

    try testing.expect(game.hasComponent(e, Tag));
    game.removeComponent(e, Tag);
    try testing.expect(!game.hasComponent(e, Tag));
}

test "Game: cascade destroy removes children" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const parent = game.createEntity();
    game.setPosition(parent, .{ .x = 0, .y = 0 });

    const child = game.createEntity();
    game.setPosition(child, .{ .x = 10, .y = 10 });
    game.setParent(child, parent, .{});

    try testing.expectEqual(2, game.entityCount());
    game.destroyEntity(parent);
    try testing.expectEqual(0, game.entityCount());
}
