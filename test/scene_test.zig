const std = @import("std");
const testing = std.testing;

const core = @import("labelle-core");

const engine = @import("engine");

const game_mod = engine.game_mod;

// ============================================================
// Test Helpers
// ============================================================

const Health = struct {
    current: f32 = 0,
    max: f32 = 100,
};

const Velocity = struct {
    x: f32 = 0,
    y: f32 = 0,
};

const TestGame = game_mod.Game;

// ============================================================
// World Management Tests
// ============================================================

test "World: createWorld and destroyWorld" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try game.createWorld("test_world");
    try testing.expect(game.worldExists("test_world"));

    game.destroyWorld("test_world");
    try testing.expect(!game.worldExists("test_world"));
}

test "World: destroyWorld on nonexistent is safe" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    game.destroyWorld("nonexistent"); // should not crash
}

test "World: setActiveWorld swaps ECS state" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    // Create two named worlds
    try game.createWorld("world_a");
    try game.createWorld("world_b");

    // Activate world_a, create entity
    try game.setActiveWorld("world_a");
    const e1 = game.createEntity();
    game.ecs_backend.addComponent(e1, Health{ .current = 42, .max = 100 });

    // Swap to world_b — entity from world_a should not be visible
    try game.setActiveWorld("world_b");
    try testing.expect(!game.ecs_backend.hasComponent(e1, Health));

    // Create entity in world_b
    const e2 = game.createEntity();
    game.ecs_backend.addComponent(e2, Velocity{ .x = 5, .y = 3 });

    // Swap back to world_a — original entity should be there
    try game.setActiveWorld("world_a");
    const health = game.ecs_backend.getComponent(e1, Health);
    try testing.expect(health != null);
    try testing.expectEqual(@as(f32, 42), health.?.current);
}

test "World: round-trip swap preserves state" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try game.createWorld("world_a");
    try game.createWorld("world_b");

    // Activate world_a, create entity
    try game.setActiveWorld("world_a");
    const ea = game.createEntity();
    game.ecs_backend.addComponent(ea, Health{ .current = 10, .max = 50 });

    // Swap to world_b, create different entity
    try game.setActiveWorld("world_b");
    _ = game.createEntity();

    // Swap back to world_a — entity should still be there
    try game.setActiveWorld("world_a");
    const health = game.ecs_backend.getComponent(ea, Health);
    try testing.expect(health != null);
    try testing.expectEqual(@as(f32, 10), health.?.current);
}

test "World: renameWorld" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try game.createWorld("old_name");
    try testing.expect(game.worldExists("old_name"));

    try game.renameWorld("old_name", "new_name");
    try testing.expect(!game.worldExists("old_name"));
    try testing.expect(game.worldExists("new_name"));
}

test "World: setActiveWorld with unknown name returns error" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    try testing.expectError(error.WorldNotFound, game.setActiveWorld("nonexistent"));
}

test "World: getActiveWorldName" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    // Initially unnamed
    try testing.expectEqual(@as(?[]const u8, null), game.getActiveWorldName());

    // After activating a named world
    try game.createWorld("my_world");
    try game.setActiveWorld("my_world");
    try testing.expectEqualStrings("my_world", game.getActiveWorldName().?);
}
