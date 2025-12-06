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
// Assertions
// =============================================================================

fn runAssertions() void {
    // Scene loaded from .zon file
    std.debug.assert(std.mem.eql(u8, test_scene.name, "ecs_test"));
    std.debug.print("  ✓ Scene loaded from .zon file (name: {s})\n", .{test_scene.name});

    // Scene has correct number of entities
    std.debug.assert(test_scene.entities.len == 3);
    std.debug.print("  ✓ Scene has {d} entities\n", .{test_scene.entities.len});

    // Scene entities reference valid prefabs
    std.debug.assert(Prefabs.get(test_scene.entities[0].prefab) != null);
    std.debug.assert(Prefabs.get(test_scene.entities[1].prefab) != null);
    std.debug.assert(Prefabs.get(test_scene.entities[2].prefab) != null);
    std.debug.print("  ✓ All scene prefabs are registered\n", .{});

    // Scene entities have correct position data
    std.debug.assert(test_scene.entities[0].x == 0 and test_scene.entities[0].y == 0);
    std.debug.assert(test_scene.entities[1].x == 50 and test_scene.entities[1].y == 50);
    std.debug.assert(test_scene.entities[2].x == 100 and test_scene.entities[2].y == 100);
    std.debug.print("  ✓ Scene entities have correct positions\n", .{});

    // Scene components are registered in ComponentRegistry
    std.debug.assert(Components.has("Health"));
    std.debug.assert(Components.has("Velocity"));
    std.debug.print("  ✓ Scene components are registered (Health, Velocity)\n", .{});

    // Scene entity Health component data is accessible
    std.debug.assert(test_scene.entities[0].components.Health.current == 100);
    std.debug.assert(test_scene.entities[0].components.Health.max == 100);
    std.debug.assert(test_scene.entities[1].components.Health.current == 30);
    std.debug.assert(test_scene.entities[1].components.Health.max == 30);
    std.debug.assert(test_scene.entities[2].components.Health.current == 50);
    std.debug.assert(test_scene.entities[2].components.Health.max == 50);
    std.debug.print("  ✓ Scene Health component data is correct\n", .{});

    // Scene entity Velocity component data is accessible
    std.debug.assert(test_scene.entities[1].components.Velocity.dx == -5);
    std.debug.assert(test_scene.entities[1].components.Velocity.dy == 0);
    std.debug.assert(test_scene.entities[2].components.Velocity.dx == 5);
    std.debug.assert(test_scene.entities[2].components.Velocity.dy == 0);
    std.debug.print("  ✓ Scene Velocity component data is correct\n", .{});

    std.debug.print("\n✅ All assertions passed!\n", .{});
}

pub fn main() void {
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
        \\Running assertions:
        \\
    , .{});

    runAssertions();
}
