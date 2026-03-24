const std = @import("std");
const testing = std.testing;

const core = @import("labelle-core");
const Position = core.Position;
const VisualType = core.VisualType;

const engine = @import("engine");
const Scene = engine.Scene;
const SceneLoader = engine.SceneLoader;
const SimpleSceneLoader = engine.SimpleSceneLoader;
const PrefabRegistry = engine.PrefabRegistry;
const ComponentRegistry = engine.ComponentRegistry;
const ScriptRegistry = engine.ScriptRegistry;
const NoScripts = engine.NoScripts;
const isReference = engine.isReference;
const extractRefInfo = engine.extractRefInfo;
const ParentComponent = engine.scene_mod.ParentComponent;
const ChildrenComponent = engine.scene_mod.ChildrenComponent;

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

const TestComponents = ComponentRegistry(.{
    .Health = Health,
    .Velocity = Velocity,
});

const TestPrefabs = PrefabRegistry(.{
    .player = .{
        .components = .{
            .Position = .{ .x = 100, .y = 200 },
            .Sprite = .{ .sprite_name = "player.png", .scale_x = 2.0, .scale_y = 2.0 },
        },
    },
    .enemy = .{
        .components = .{
            .Sprite = .{ .sprite_name = "enemy.png" },
            .Health = .{ .current = 50, .max = 50 },
        },
    },
    .rock = .{
        .components = .{
            .Position = .{ .x = 0, .y = 0 },
        },
    },
});

// Test script module
const test_script = struct {
    var init_called: bool = false;
    var update_count: u32 = 0;
    var deinit_called: bool = false;

    pub fn init(_: *anyopaque, _: *anyopaque) void {
        init_called = true;
    }
    pub fn update(_: *anyopaque, _: *anyopaque, _: f32) void {
        update_count += 1;
    }
    pub fn deinit(_: *anyopaque, _: *anyopaque) void {
        deinit_called = true;
    }

    fn reset() void {
        init_called = false;
        update_count = 0;
        deinit_called = false;
    }
};

const TestScripts = ScriptRegistry(struct {
    pub const movement = test_script;
});

const TestGame = game_mod.Game;
const TestLoader = SceneLoader(TestGame, TestPrefabs, TestComponents, TestScripts);
const SimpleTestLoader = SimpleSceneLoader(TestGame, TestPrefabs, TestComponents);
const TestScene = Scene(TestGame.EntityType);

// ============================================================
// Scene Loading Tests
// ============================================================

test "Scene: load simple prefab entity" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    var scene = try SimpleTestLoader.load(.{
        .name = "test",
        .entities = .{
            .{ .prefab = "player" },
        },
    }, &game, testing.allocator);
    defer scene.deinit();

    try testing.expectEqual(1, scene.entityCount());
    try testing.expectEqualStrings("test", scene.name);
    try testing.expectEqualStrings("player", scene.entities.items[0].prefab_name.?);
    try testing.expectEqual(VisualType.sprite, scene.entities.items[0].visual_type);
}

test "Scene: prefab position from prefab defaults" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    var scene = try SimpleTestLoader.load(.{
        .name = "pos_test",
        .entities = .{
            .{ .prefab = "player" },
        },
    }, &game, testing.allocator);
    defer scene.deinit();

    const entity = scene.entities.items[0].entity;
    const pos = game.ecs_backend.getComponent(entity, Position).?;
    try testing.expectEqual(100.0, pos.x);
    try testing.expectEqual(200.0, pos.y);
}

test "Scene: prefab position overridden by scene" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    var scene = try SimpleTestLoader.load(.{
        .name = "override_test",
        .entities = .{
            .{ .prefab = "player", .components = .{ .Position = .{ .x = 500, .y = 300 } } },
        },
    }, &game, testing.allocator);
    defer scene.deinit();

    const entity = scene.entities.items[0].entity;
    const pos = game.ecs_backend.getComponent(entity, Position).?;
    try testing.expectEqual(500.0, pos.x);
    try testing.expectEqual(300.0, pos.y);
}

test "Scene: inline entity with components" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    var scene = try SimpleTestLoader.load(.{
        .name = "inline_test",
        .entities = .{
            .{
                .components = .{
                    .Position = .{ .x = 200, .y = 150 },
                    .Sprite = .{ .sprite_name = "gem" },
                },
            },
        },
    }, &game, testing.allocator);
    defer scene.deinit();

    try testing.expectEqual(1, scene.entityCount());
    try testing.expectEqual(VisualType.sprite, scene.entities.items[0].visual_type);
    try testing.expect(scene.entities.items[0].prefab_name == null);
}

test "Scene: custom component via registry" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    var scene = try SimpleTestLoader.load(.{
        .name = "custom_comp_test",
        .entities = .{
            .{
                .components = .{
                    .Position = .{ .x = 0, .y = 0 },
                    .Health = .{ .current = 75, .max = 100 },
                },
            },
        },
    }, &game, testing.allocator);
    defer scene.deinit();

    const entity = scene.entities.items[0].entity;
    const health = game.ecs_backend.getComponent(entity, Health).?;
    try testing.expectEqual(75.0, health.current);
    try testing.expectEqual(100.0, health.max);
}

test "Scene: prefab with component override (merging)" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    var scene = try SimpleTestLoader.load(.{
        .name = "merge_test",
        .entities = .{
            .{
                .prefab = "enemy",
                .components = .{
                    .Health = .{ .current = 25 },
                },
            },
        },
    }, &game, testing.allocator);
    defer scene.deinit();

    const entity = scene.entities.items[0].entity;
    const health = game.ecs_backend.getComponent(entity, Health).?;
    try testing.expectEqual(25.0, health.current);
    try testing.expectEqual(50.0, health.max);
}

test "Scene: prefab with extra scene-only component" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    var scene = try SimpleTestLoader.load(.{
        .name = "extra_comp_test",
        .entities = .{
            .{
                .prefab = "player",
                .components = .{
                    .Velocity = .{ .x = 10, .y = 0 },
                },
            },
        },
    }, &game, testing.allocator);
    defer scene.deinit();

    const entity = scene.entities.items[0].entity;
    const vel = game.ecs_backend.getComponent(entity, Velocity).?;
    try testing.expectEqual(10.0, vel.x);
    try testing.expectEqual(0.0, vel.y);
}

test "Scene: multiple entities" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    var scene = try SimpleTestLoader.load(.{
        .name = "multi_test",
        .entities = .{
            .{ .prefab = "player" },
            .{ .prefab = "enemy" },
            .{ .components = .{ .Position = .{ .x = 50, .y = 75 }, .Health = .{ .current = 100 } } },
        },
    }, &game, testing.allocator);
    defer scene.deinit();

    try testing.expectEqual(3, scene.entityCount());
}

test "Scene: data-only entity (no visual)" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    var scene = try SimpleTestLoader.load(.{
        .name = "data_only",
        .entities = .{
            .{
                .components = .{
                    .Position = .{ .x = 10, .y = 20 },
                    .Health = .{ .current = 100, .max = 100 },
                },
            },
        },
    }, &game, testing.allocator);
    defer scene.deinit();

    try testing.expectEqual(VisualType.none, scene.entities.items[0].visual_type);
}

test "Scene: scripts lifecycle" {
    test_script.reset();

    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    var scene = try TestLoader.load(.{
        .name = "script_test",
        .scripts = .{"movement"},
        .entities = .{
            .{ .prefab = "player" },
        },
    }, &game, testing.allocator);

    try testing.expect(!test_script.init_called);

    // First update triggers init
    scene.update(0.016);
    try testing.expect(test_script.init_called);
    try testing.expectEqual(1, test_script.update_count);

    // Subsequent updates
    scene.update(0.016);
    scene.update(0.016);
    try testing.expectEqual(3, test_script.update_count);

    // Deinit fires on scene deinit
    try testing.expect(!test_script.deinit_called);
    scene.deinit();
    try testing.expect(test_script.deinit_called);
}

test "Scene: removeEntity" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    var scene = try SimpleTestLoader.load(.{
        .name = "remove_test",
        .entities = .{
            .{ .prefab = "player" },
            .{ .prefab = "enemy" },
        },
    }, &game, testing.allocator);
    defer scene.deinit();

    try testing.expectEqual(2, scene.entityCount());

    const player_entity = scene.entities.items[0].entity;
    scene.removeEntity(player_entity);
    try testing.expectEqual(1, scene.entityCount());
}

test "Scene: instantiatePrefab at runtime" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    var scene = try SimpleTestLoader.load(.{
        .name = "runtime_test",
        .entities = .{},
    }, &game, testing.allocator);
    defer scene.deinit();

    try testing.expectEqual(0, scene.entityCount());

    const entity = try SimpleTestLoader.instantiatePrefab("player", &scene, &game, 300, 400);
    try testing.expectEqual(1, scene.entityCount());

    const pos = game.ecs_backend.getComponent(entity, Position).?;
    try testing.expectEqual(300.0, pos.x);
    try testing.expectEqual(400.0, pos.y);
}

// ============================================================
// Entity Reference Tests
// ============================================================

const Follower = struct {
    target: u32 = 0, // Entity type
    speed: f32 = 1.0,
};

const RefTestComponents = ComponentRegistry(.{
    .Health = Health,
    .Velocity = Velocity,
    .Follower = Follower,
});

const RefTestLoader = SceneLoader(TestGame, TestPrefabs, RefTestComponents, NoScripts);

test "isReference: detects reference markers" {
    try testing.expect(isReference(.{ .ref = .self }));
    try testing.expect(isReference(.{ .ref = .{ .entity = "player" } }));
    try testing.expect(isReference(.{ .ref = .{ .id = "player_1" } }));
    try testing.expect(!isReference(.{ .x = 10 }));
    try testing.expect(!isReference(.{ .name = "test" }));
}

test "extractRefInfo: self reference" {
    const info = extractRefInfo(.{ .ref = .self }).?;
    try testing.expect(info.is_self);
    try testing.expect(info.ref_key == null);
    try testing.expect(!info.is_id_ref);
}

test "extractRefInfo: entity name reference" {
    const info = extractRefInfo(.{ .ref = .{ .entity = "player" } }).?;
    try testing.expect(!info.is_self);
    try testing.expectEqualStrings("player", info.ref_key.?);
    try testing.expect(!info.is_id_ref);
}

test "extractRefInfo: entity ID reference" {
    const info = extractRefInfo(.{ .ref = .{ .id = "player_1" } }).?;
    try testing.expect(!info.is_self);
    try testing.expectEqualStrings("player_1", info.ref_key.?);
    try testing.expect(info.is_id_ref);
}

test "generateAutoId: produces indexed IDs" {
    const generateAutoId = engine.scene_mod.generateAutoId;
    try testing.expectEqualStrings("_e0", generateAutoId(0));
    try testing.expectEqualStrings("_e1", generateAutoId(1));
    try testing.expectEqualStrings("_e42", generateAutoId(42));
}

test "getEntityId: explicit ID takes precedence" {
    const getEntityId = engine.scene_mod.getEntityId;
    try testing.expectEqualStrings("my_id", getEntityId(.{ .id = "my_id" }, 5));
    try testing.expectEqualStrings("_e5", getEntityId(.{ .name = "foo" }, 5));
    try testing.expectEqualStrings("_e0", getEntityId(.{}, 0));
}

test "Scene: entity reference by name" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    var scene = try RefTestLoader.load(.{
        .name = "ref_test",
        .entities = .{
            .{ .name = "leader", .components = .{ .Position = .{ .x = 100, .y = 100 }, .Health = .{ .current = 100 } } },
            .{ .components = .{ .Position = .{ .x = 200, .y = 200 }, .Follower = .{ .target = .{ .ref = .{ .entity = "leader" } }, .speed = 2.0 } } },
        },
    }, &game, testing.allocator);
    defer scene.deinit();

    try testing.expectEqual(2, scene.entityCount());

    const leader_entity = scene.entities.items[0].entity;
    const follower_entity = scene.entities.items[1].entity;

    // Follower's target should be resolved to the leader entity
    const follower = game.ecs_backend.getComponent(follower_entity, Follower).?;
    try testing.expectEqual(leader_entity, follower.target);
    try testing.expectEqual(2.0, follower.speed);
}

test "Scene: entity self-reference" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    var scene = try RefTestLoader.load(.{
        .name = "self_ref_test",
        .entities = .{
            .{ .components = .{ .Position = .{ .x = 0, .y = 0 }, .Follower = .{ .target = .{ .ref = .self } } } },
        },
    }, &game, testing.allocator);
    defer scene.deinit();

    const entity = scene.entities.items[0].entity;
    const follower = game.ecs_backend.getComponent(entity, Follower).?;
    try testing.expectEqual(entity, follower.target);
}

test "Scene: entity reference by ID" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    var scene = try RefTestLoader.load(.{
        .name = "id_ref_test",
        .entities = .{
            .{ .id = "hero_1", .components = .{ .Position = .{ .x = 50, .y = 50 } } },
            .{ .components = .{ .Position = .{ .x = 200, .y = 200 }, .Follower = .{ .target = .{ .ref = .{ .id = "hero_1" } } } } },
        },
    }, &game, testing.allocator);
    defer scene.deinit();

    const hero_entity = scene.entities.items[0].entity;
    const follower_entity = scene.entities.items[1].entity;
    const follower = game.ecs_backend.getComponent(follower_entity, Follower).?;
    try testing.expectEqual(hero_entity, follower.target);
}

test "Scene: forward entity reference (child before parent)" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    // Follower is defined BEFORE the leader -- forward reference
    var scene = try RefTestLoader.load(.{
        .name = "forward_ref_test",
        .entities = .{
            .{ .components = .{ .Position = .{ .x = 200, .y = 200 }, .Follower = .{ .target = .{ .ref = .{ .entity = "leader" } } } } },
            .{ .name = "leader", .components = .{ .Position = .{ .x = 100, .y = 100 } } },
        },
    }, &game, testing.allocator);
    defer scene.deinit();

    const follower_entity = scene.entities.items[0].entity;
    const leader_entity = scene.entities.items[1].entity;
    const follower = game.ecs_backend.getComponent(follower_entity, Follower).?;
    try testing.expectEqual(leader_entity, follower.target);
}

// ============================================================
// Parent-Child Hierarchy Tests
// ============================================================

test "Scene: parent-child via .parent field" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const Parent = ParentComponent(u32);
    const Children = ChildrenComponent(u32);

    var scene = try RefTestLoader.load(.{
        .name = "parent_test",
        .entities = .{
            .{ .name = "parent", .components = .{ .Position = .{ .x = 100, .y = 100 } } },
            .{ .name = "child", .parent = "parent", .components = .{ .Position = .{ .x = 150, .y = 150 } } },
        },
    }, &game, testing.allocator);
    defer scene.deinit();

    const parent_entity = scene.entities.items[0].entity;
    const child_entity = scene.entities.items[1].entity;

    // Child should have Parent component
    const parent_comp = game.ecs_backend.getComponent(child_entity, Parent).?;
    try testing.expectEqual(parent_entity, parent_comp.entity);

    // Parent should have Children component
    const children_comp = game.ecs_backend.getComponent(parent_entity, Children).?;
    try testing.expectEqual(1, children_comp.count());
    try testing.expectEqual(child_entity, children_comp.getChildren()[0]);
}

test "Scene: parent-child forward reference (child before parent in .zon)" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const Parent = ParentComponent(u32);

    // Child defined BEFORE parent -- forward reference
    var scene = try RefTestLoader.load(.{
        .name = "forward_parent_test",
        .entities = .{
            .{ .name = "child", .parent = "the_parent", .components = .{ .Position = .{ .x = 0, .y = 0 } } },
            .{ .name = "the_parent", .components = .{ .Position = .{ .x = 50, .y = 50 } } },
        },
    }, &game, testing.allocator);
    defer scene.deinit();

    const child_entity = scene.entities.items[0].entity;
    const parent_entity = scene.entities.items[1].entity;

    const parent_comp = game.ecs_backend.getComponent(child_entity, Parent).?;
    try testing.expectEqual(parent_entity, parent_comp.entity);
}

// ============================================================
// onReady Callback Tests
// ============================================================

const OnReadyTracker = struct {
    var ready_called: bool = false;
    var health_seen_at_ready: ?f32 = null;
    var velocity_seen_at_ready: ?f32 = null;

    fn reset() void {
        ready_called = false;
        health_seen_at_ready = null;
        velocity_seen_at_ready = null;
    }
};

const ReadyHealth = struct {
    current: f32 = 0,
    max: f32 = 100,

    pub fn onReady(payload: engine.ComponentPayload) void {
        const game = payload.getGame(TestGame);
        const entity: u32 = @intCast(payload.entity_id);
        OnReadyTracker.ready_called = true;
        // At onReady time, sibling components should be accessible
        if (game.getComponent(entity, ReadyVelocity)) |vel| {
            OnReadyTracker.velocity_seen_at_ready = vel.x;
        }
    }
};

const ReadyVelocity = struct {
    x: f32 = 0,
    y: f32 = 0,

    pub fn onReady(payload: engine.ComponentPayload) void {
        const game = payload.getGame(TestGame);
        const entity: u32 = @intCast(payload.entity_id);
        // At onReady time, sibling components should be accessible
        if (game.getComponent(entity, ReadyHealth)) |hp| {
            OnReadyTracker.health_seen_at_ready = hp.current;
        }
    }
};

const ReadyComponents = ComponentRegistry(.{
    .Health = ReadyHealth,
    .Velocity = ReadyVelocity,
});

const ReadyTestLoader = SimpleSceneLoader(TestGame, TestPrefabs, ReadyComponents);

test "Scene: onReady fires after all components are added" {
    OnReadyTracker.reset();
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    var scene = try ReadyTestLoader.load(.{
        .name = "ready_test",
        .entities = .{
            .{
                .components = .{
                    .Position = .{ .x = 0, .y = 0 },
                    .Health = .{ .current = 80, .max = 100 },
                    .Velocity = .{ .x = 5, .y = 0 },
                },
            },
        },
    }, &game, testing.allocator);
    defer scene.deinit();

    // onReady should have fired
    try testing.expect(OnReadyTracker.ready_called);
}

test "Scene: onReady can access sibling components" {
    OnReadyTracker.reset();
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    var scene = try ReadyTestLoader.load(.{
        .name = "ready_sibling_test",
        .entities = .{
            .{
                .components = .{
                    .Position = .{ .x = 0, .y = 0 },
                    .Health = .{ .current = 42, .max = 100 },
                    .Velocity = .{ .x = 7, .y = 0 },
                },
            },
        },
    }, &game, testing.allocator);
    defer scene.deinit();

    // ReadyHealth.onReady should have seen Velocity
    try testing.expect(OnReadyTracker.velocity_seen_at_ready != null);
    try testing.expectEqual(7.0, OnReadyTracker.velocity_seen_at_ready.?);

    // ReadyVelocity.onReady should have seen Health
    try testing.expect(OnReadyTracker.health_seen_at_ready != null);
    try testing.expectEqual(42.0, OnReadyTracker.health_seen_at_ready.?);
}

test "Scene: multiple children under one parent" {
    var game = TestGame.init(testing.allocator);
    defer game.deinit();

    const Children = ChildrenComponent(u32);

    var scene = try RefTestLoader.load(.{
        .name = "multi_child_test",
        .entities = .{
            .{ .name = "root", .components = .{ .Position = .{ .x = 0, .y = 0 } } },
            .{ .parent = "root", .components = .{ .Position = .{ .x = 10, .y = 10 } } },
            .{ .parent = "root", .components = .{ .Position = .{ .x = 20, .y = 20 } } },
            .{ .parent = "root", .components = .{ .Position = .{ .x = 30, .y = 30 } } },
        },
    }, &game, testing.allocator);
    defer scene.deinit();

    const root_entity = scene.entities.items[0].entity;
    const children_comp = game.ecs_backend.getComponent(root_entity, Children).?;
    try testing.expectEqual(3, children_comp.count());
}

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

    // Name the default world by creating + swapping
    try game.createWorld("main");
    // Move current state to "default" first
    try game.createWorld("default");

    // Create entity in active (unnamed) world
    const e1 = game.createEntity();
    game.ecs_backend.addComponent(e1, Health{ .current = 10, .max = 50 });

    // Swap to "main" (shelves current unnamed world — but unnamed can't be retrieved)
    // Instead, let's test with named worlds only:

    // Start fresh
    var game2 = TestGame.init(testing.allocator);
    defer game2.deinit();

    // Create two named worlds
    try game2.createWorld("world_a");
    try game2.createWorld("world_b");

    // Activate world_a, create entity
    try game2.setActiveWorld("world_a");
    const ea = game2.createEntity();
    game2.ecs_backend.addComponent(ea, Health{ .current = 10, .max = 50 });

    // Swap to world_b, create different entity
    try game2.setActiveWorld("world_b");
    const eb = game2.createEntity();
    game2.ecs_backend.addComponent(eb, Velocity{ .x = 5, .y = 3 });

    // Swap back to world_a — entity should still be there
    try game2.setActiveWorld("world_a");
    const health = game2.ecs_backend.getComponent(ea, Health);
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
