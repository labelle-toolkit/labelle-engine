//! Example 2: Scene Loading Verification
//!
//! This example verifies that scene data loaded from a .zon file has its
//! components properly registered and available in the ECS registry.

const std = @import("std");
const engine = @import("labelle-engine");
const ecs = @import("ecs");

// =============================================================================
// Scene loaded from .zon file
// =============================================================================

pub const test_scene = @import("test_scene.zon");

// =============================================================================
// Components (as defined in the scene)
// =============================================================================

pub const Velocity = struct {
    dx: f32 = 0,
    dy: f32 = 0,
};

pub const Health = struct {
    current: i32 = 100,
    max: i32 = 100,
};

// =============================================================================
// Prefabs
// =============================================================================

const PlayerPrefab = struct {
    pub const name = "player";
    pub const sprite = engine.prefab.SpriteConfig{
        .name = "player.png",
    };
};

const EnemyPrefab = struct {
    pub const name = "enemy";
    pub const sprite = engine.prefab.SpriteConfig{
        .name = "enemy.png",
    };
};

const example = @This();

pub const Prefabs = engine.PrefabRegistry(.{ PlayerPrefab, EnemyPrefab });

pub const Components = engine.ComponentRegistry(struct {
    pub const Velocity = example.Velocity;
    pub const Health = example.Health;
});

// =============================================================================
// Tests
// =============================================================================

fn runTests() !void {
    var passed: usize = 0;
    var failed: usize = 0;

    // Test 1: Scene loaded from .zon file
    {
        if (std.mem.eql(u8, test_scene.name, "ecs_test")) {
            std.debug.print("  ✓ Scene loaded from .zon file (name: {s})\n", .{test_scene.name});
            passed += 1;
        } else {
            std.debug.print("  ✗ Scene name mismatch\n", .{});
            failed += 1;
        }
    }

    // Test 2: Scene has correct number of entities
    {
        if (test_scene.entities.len == 3) {
            std.debug.print("  ✓ Scene has {d} entities\n", .{test_scene.entities.len});
            passed += 1;
        } else {
            std.debug.print("  ✗ Scene entity count wrong (expected 3, got {})\n", .{test_scene.entities.len});
            failed += 1;
        }
    }

    // Test 3: Scene entities reference valid prefabs
    {
        const player_prefab = test_scene.entities[0].prefab;
        const enemy1_prefab = test_scene.entities[1].prefab;
        const enemy2_prefab = test_scene.entities[2].prefab;

        const all_valid = Prefabs.get(player_prefab) != null and
            Prefabs.get(enemy1_prefab) != null and
            Prefabs.get(enemy2_prefab) != null;

        if (all_valid) {
            std.debug.print("  ✓ All scene prefabs are registered\n", .{});
            passed += 1;
        } else {
            std.debug.print("  ✗ Scene references unregistered prefabs\n", .{});
            failed += 1;
        }
    }

    // Test 4: Scene entities have position data
    {
        const e1 = test_scene.entities[0];
        const e2 = test_scene.entities[1];
        const e3 = test_scene.entities[2];

        if (e1.x == 0 and e1.y == 0 and
            e2.x == 50 and e2.y == 50 and
            e3.x == 100 and e3.y == 100)
        {
            std.debug.print("  ✓ Scene entities have correct positions\n", .{});
            passed += 1;
        } else {
            std.debug.print("  ✗ Scene position data incorrect\n", .{});
            failed += 1;
        }
    }

    // Test 5: Scene components are registered in ComponentRegistry
    {
        if (Components.has("Health") and Components.has("Velocity")) {
            std.debug.print("  ✓ Scene components are registered (Health, Velocity)\n", .{});
            passed += 1;
        } else {
            std.debug.print("  ✗ Scene components not registered\n", .{});
            failed += 1;
        }
    }

    // Test 6: Scene entity Health component data is accessible
    {
        const player_health = test_scene.entities[0].components.Health;
        const enemy1_health = test_scene.entities[1].components.Health;
        const enemy2_health = test_scene.entities[2].components.Health;

        if (player_health.current == 100 and player_health.max == 100 and
            enemy1_health.current == 30 and enemy1_health.max == 30 and
            enemy2_health.current == 50 and enemy2_health.max == 50)
        {
            std.debug.print("  ✓ Scene Health component data is correct\n", .{});
            passed += 1;
        } else {
            std.debug.print("  ✗ Scene Health component data incorrect\n", .{});
            failed += 1;
        }
    }

    // Test 7: Scene entity Velocity component data is accessible
    {
        const enemy1_vel = test_scene.entities[1].components.Velocity;
        const enemy2_vel = test_scene.entities[2].components.Velocity;

        if (enemy1_vel.dx == -5 and enemy1_vel.dy == 0 and
            enemy2_vel.dx == 5 and enemy2_vel.dy == 0)
        {
            std.debug.print("  ✓ Scene Velocity component data is correct\n", .{});
            passed += 1;
        } else {
            std.debug.print("  ✗ Scene Velocity component data incorrect\n", .{});
            failed += 1;
        }
    }

    // Summary
    std.debug.print("\n", .{});
    const total = passed + failed;
    if (failed == 0) {
        std.debug.print("✅ All {d} tests passed!\n", .{total});
    } else {
        std.debug.print("❌ {d}/{d} tests passed ({d} failed)\n", .{ passed, total, failed });
        std.process.exit(1);
    }
}

pub fn main() !void {
    std.debug.print(
        \\
        \\Scene Loading Verification Example
        \\===================================
        \\
        \\This example verifies that:
        \\1. Scene data can be loaded from a .zon file
        \\2. Scene prefabs are registered in PrefabRegistry
        \\3. Scene components are registered in ComponentRegistry
        \\4. Component data from the scene is accessible
        \\
        \\Scene file: test_scene.zon
        \\
        \\Running tests:
        \\
    , .{});

    try runTests();
}
