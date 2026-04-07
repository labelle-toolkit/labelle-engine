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
    const EmptyComponents = struct {
        pub fn has(comptime _: []const u8) bool { return false; }
        pub fn names() []const []const u8 { return &.{}; }
    };
    const CustomGame = GameConfig(
        TestRenderer,
        MockEcsBackend(u32),
        StubInput,
        StubAudio,
        StubGui,
        void,
        StubLogSink,
        EmptyComponents,
        &.{}, // no gizmo categories
        void, // no game events
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

// ── Entity liveness guards (#419) ──────────────────────────────

test "Game: destroyed entity is no longer alive" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const e = game.createEntity();
    game.setPosition(e, .{ .x = 1, .y = 2 });
    try testing.expect(game.ecs_backend.entityExists(e));

    game.destroyEntity(e);
    try testing.expect(!game.ecs_backend.entityExists(e));
}

test "Game: read-only ops on destroyed entity return null/default" {
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const Tag = struct { label: u32 };
    const e = game.createEntity();
    game.addComponent(e, Tag{ .label = 42 });
    game.setPosition(e, .{ .x = 5, .y = 10 });
    game.destroyEntity(e);

    // getComponent returns null — safe, no panic
    try testing.expectEqual(@as(?*Tag, null), game.getComponent(e, Tag));
    // hasComponent returns false — safe, no panic
    try testing.expect(!game.hasComponent(e, Tag));
    // getPosition returns default — safe, no panic
    const pos = game.getPosition(e);
    try testing.expectEqual(0.0, pos.x);
    try testing.expectEqual(0.0, pos.y);
}

// ── Tombstone tracking (#420) ──────────────────────────────────

test "Game: tombstone records frame number" {
    if (@import("builtin").mode != .Debug) return;
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const e = game.createEntity();
    game.frame_number = 42;
    game.destroyEntity(e);

    const tomb = game.findTombstone(e);
    try testing.expect(tomb != null);
    try testing.expectEqual(42, tomb.?.frame);
    try testing.expectEqual(e, tomb.?.entity);
}

test "Game: tombstone ring wraps around" {
    if (@import("builtin").mode != .Debug) return;
    var game = Game.init(testing.allocator);
    defer game.deinit();

    // Fill the ring buffer beyond capacity
    var first_entity: Game.EntityType = undefined;
    for (0..Game.tombstone_size + 10) |i| {
        const e = game.createEntity();
        if (i == 0) first_entity = e;
        game.frame_number = @intCast(i);
        game.destroyEntity(e);
    }

    // First entity should have been evicted from the ring
    try testing.expectEqual(@as(?Game.TombstoneEntry, null), game.findTombstone(first_entity));

    // Recent entities should still be in the ring
    const last = game.createEntity();
    game.frame_number = 999;
    game.destroyEntity(last);
    const tomb = game.findTombstone(last);
    try testing.expect(tomb != null);
    try testing.expectEqual(999, tomb.?.frame);
}

test "Game: cascade destroy records tombstones for parent and children" {
    if (@import("builtin").mode != .Debug) return;
    var game = Game.init(testing.allocator);
    defer game.deinit();

    const parent = game.createEntity();
    game.setPosition(parent, .{ .x = 0, .y = 0 });
    const child = game.createEntity();
    game.setPosition(child, .{ .x = 10, .y = 10 });
    game.setParent(child, parent, .{});

    game.frame_number = 100;
    game.destroyEntity(parent);

    // Both parent and child should have tombstones
    const parent_tomb = game.findTombstone(parent);
    try testing.expect(parent_tomb != null);
    try testing.expectEqual(100, parent_tomb.?.frame);

    const child_tomb = game.findTombstone(child);
    try testing.expect(child_tomb != null);
    try testing.expectEqual(100, child_tomb.?.frame);
}
