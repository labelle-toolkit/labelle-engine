//! Example 2: ECS Component Verification
//!
//! This example demonstrates that components defined in scenes are properly
//! added to the ECS registry and can be queried.

const std = @import("std");
const engine = @import("labelle-engine");
const ecs = @import("ecs");

// =============================================================================
// Components
// =============================================================================

pub const Position = struct {
    x: f32 = 0,
    y: f32 = 0,
};

pub const Velocity = struct {
    dx: f32 = 0,
    dy: f32 = 0,
};

pub const Health = struct {
    current: i32 = 100,
    max: i32 = 100,

    pub fn isDead(self: Health) bool {
        return self.current <= 0;
    }

    pub fn percentage(self: Health) f32 {
        return @as(f32, @floatFromInt(self.current)) / @as(f32, @floatFromInt(self.max));
    }
};

pub const Player = struct {
    name: []const u8 = "Player",
    score: i32 = 0,
};

pub const Enemy = struct {
    damage: i32 = 10,
    aggro_range: f32 = 100,
};

// =============================================================================
// Component Registry
// =============================================================================

const example = @This();

pub const Components = engine.ComponentRegistry(struct {
    pub const Position = example.Position;
    pub const Velocity = example.Velocity;
    pub const Health = example.Health;
    pub const Player = example.Player;
    pub const Enemy = example.Enemy;
});

// =============================================================================
// Tests
// =============================================================================

fn runTests(allocator: std.mem.Allocator) !void {
    var passed: usize = 0;
    var failed: usize = 0;

    // Test 1: Component registry has all components
    {
        const has_all = Components.has("Position") and
            Components.has("Velocity") and
            Components.has("Health") and
            Components.has("Player") and
            Components.has("Enemy");

        if (has_all) {
            std.debug.print("  ✓ Component registry has all components\n", .{});
            passed += 1;
        } else {
            std.debug.print("  ✗ Component registry missing components\n", .{});
            failed += 1;
        }
    }

    // Test 2: ECS registry can store and retrieve Position component
    {
        var registry = ecs.Registry.init(allocator);
        defer registry.deinit();

        const entity = registry.create();
        registry.add(entity, Position{ .x = 100, .y = 200 });

        if (registry.tryGet(Position, entity)) |pos| {
            if (pos.x == 100 and pos.y == 200) {
                std.debug.print("  ✓ ECS registry stores Position component\n", .{});
                passed += 1;
            } else {
                std.debug.print("  ✗ ECS registry Position values wrong\n", .{});
                failed += 1;
            }
        } else {
            std.debug.print("  ✗ ECS registry failed to store Position\n", .{});
            failed += 1;
        }
    }

    // Test 3: ECS registry can store and retrieve Velocity component
    {
        var registry = ecs.Registry.init(allocator);
        defer registry.deinit();

        const entity = registry.create();
        registry.add(entity, Velocity{ .dx = 5.5, .dy = -3.2 });

        if (registry.tryGet(Velocity, entity)) |vel| {
            if (vel.dx == 5.5 and vel.dy == -3.2) {
                std.debug.print("  ✓ ECS registry stores Velocity component\n", .{});
                passed += 1;
            } else {
                std.debug.print("  ✗ ECS registry Velocity values wrong\n", .{});
                failed += 1;
            }
        } else {
            std.debug.print("  ✗ ECS registry failed to store Velocity\n", .{});
            failed += 1;
        }
    }

    // Test 4: ECS registry can store and retrieve Health component
    {
        var registry = ecs.Registry.init(allocator);
        defer registry.deinit();

        const entity = registry.create();
        registry.add(entity, Health{ .current = 75, .max = 100 });

        if (registry.tryGet(Health, entity)) |health| {
            if (health.current == 75 and health.max == 100) {
                std.debug.print("  ✓ ECS registry stores Health component\n", .{});
                passed += 1;
            } else {
                std.debug.print("  ✗ ECS registry Health values wrong\n", .{});
                failed += 1;
            }
        } else {
            std.debug.print("  ✗ ECS registry failed to store Health\n", .{});
            failed += 1;
        }
    }

    // Test 5: Health component methods work correctly
    {
        const health = Health{ .current = 50, .max = 100 };
        const dead_health = Health{ .current = 0, .max = 100 };

        if (!health.isDead() and dead_health.isDead() and health.percentage() == 0.5) {
            std.debug.print("  ✓ Health component methods work\n", .{});
            passed += 1;
        } else {
            std.debug.print("  ✗ Health component methods failed\n", .{});
            failed += 1;
        }
    }

    // Test 6: Multiple components on same entity
    {
        var registry = ecs.Registry.init(allocator);
        defer registry.deinit();

        const entity = registry.create();
        registry.add(entity, Position{ .x = 10, .y = 20 });
        registry.add(entity, Velocity{ .dx = 1, .dy = 2 });
        registry.add(entity, Health{ .current = 100, .max = 100 });
        registry.add(entity, Player{ .name = "Hero", .score = 500 });

        const has_pos = registry.tryGet(Position, entity) != null;
        const has_vel = registry.tryGet(Velocity, entity) != null;
        const has_health = registry.tryGet(Health, entity) != null;
        const has_player = registry.tryGet(Player, entity) != null;

        if (has_pos and has_vel and has_health and has_player) {
            std.debug.print("  ✓ Multiple components on same entity\n", .{});
            passed += 1;
        } else {
            std.debug.print("  ✗ Failed to add multiple components\n", .{});
            failed += 1;
        }
    }

    // Test 7: Component query with view
    {
        var registry = ecs.Registry.init(allocator);
        defer registry.deinit();

        // Create entities with different component combinations
        const player_entity = registry.create();
        registry.add(player_entity, Position{ .x = 0, .y = 0 });
        registry.add(player_entity, Health{ .current = 100, .max = 100 });
        registry.add(player_entity, Player{});

        const enemy1 = registry.create();
        registry.add(enemy1, Position{ .x = 50, .y = 50 });
        registry.add(enemy1, Health{ .current = 30, .max = 30 });
        registry.add(enemy1, Enemy{ .damage = 10 });

        const enemy2 = registry.create();
        registry.add(enemy2, Position{ .x = 100, .y = 100 });
        registry.add(enemy2, Health{ .current = 50, .max = 50 });
        registry.add(enemy2, Enemy{ .damage = 20 });

        // Query all entities with Position and Health using view
        var view = registry.view(.{ Position, Health }, .{});
        var count: usize = 0;
        var iter = view.entityIterator();
        while (iter.next()) |_| {
            count += 1;
        }

        if (count == 3) {
            std.debug.print("  ✓ Component view query works (found 3 entities)\n", .{});
            passed += 1;
        } else {
            std.debug.print("  ✗ Component view query failed (found {} entities)\n", .{count});
            failed += 1;
        }
    }

    // Test 8: Query specific component combination (Enemy + Health)
    {
        var registry = ecs.Registry.init(allocator);
        defer registry.deinit();

        // Player (no Enemy component)
        const player_entity = registry.create();
        registry.add(player_entity, Health{ .current = 100, .max = 100 });
        registry.add(player_entity, Player{});

        // Enemies
        const enemy1 = registry.create();
        registry.add(enemy1, Health{ .current = 30, .max = 30 });
        registry.add(enemy1, Enemy{});

        const enemy2 = registry.create();
        registry.add(enemy2, Health{ .current = 50, .max = 50 });
        registry.add(enemy2, Enemy{});

        // Query only enemies (entities with Enemy + Health) using view
        var view = registry.view(.{ Health, Enemy }, .{});
        var enemy_count: usize = 0;
        var total_health: i32 = 0;
        var iter = view.entityIterator();
        while (iter.next()) |entity| {
            const health = view.get(Health, entity);
            enemy_count += 1;
            total_health += health.current;
        }

        if (enemy_count == 2 and total_health == 80) {
            std.debug.print("  ✓ Filtered query works (2 enemies, 80 total health)\n", .{});
            passed += 1;
        } else {
            std.debug.print("  ✗ Filtered query failed\n", .{});
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print(
        \\
        \\ECS Component Verification Example
        \\===================================
        \\
        \\This example verifies that:
        \\1. Components are properly registered in ComponentRegistry
        \\2. Components can be added to ECS entities
        \\3. Components can be queried from the ECS registry
        \\4. Component views/queries work correctly
        \\
        \\Running tests:
        \\
    , .{});

    try runTests(allocator);
}
