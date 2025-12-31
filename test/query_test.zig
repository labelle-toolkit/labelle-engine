//! Tests for the ECS Query API
//!
//! Tests the unified query API across backends.

const std = @import("std");
const testing = std.testing;
const ecs = @import("ecs");

// Test components
const Position = struct {
    x: f32,
    y: f32,
};

const Velocity = struct {
    dx: f32,
    dy: f32,
};

const TagPlayer = struct {};

test "query: basic each with two components" {
    var registry = ecs.Registry.init(testing.allocator);
    defer registry.deinit();

    // Create entities with components
    const e1 = registry.create();
    registry.add(e1, Position{ .x = 10, .y = 20 });
    registry.add(e1, Velocity{ .dx = 1, .dy = 2 });

    const e2 = registry.create();
    registry.add(e2, Position{ .x = 30, .y = 40 });
    registry.add(e2, Velocity{ .dx = 3, .dy = 4 });

    // Query and mutate
    var q = registry.query(.{ Position, Velocity });
    q.each(struct {
        fn run(_: ecs.Entity, pos: *Position, vel: *Velocity) void {
            pos.x += vel.dx;
            pos.y += vel.dy;
        }
    }.run);

    // Verify mutations
    const pos1 = registry.tryGet(Position, e1).?;
    try testing.expectEqual(@as(f32, 11), pos1.x);
    try testing.expectEqual(@as(f32, 22), pos1.y);

    const pos2 = registry.tryGet(Position, e2).?;
    try testing.expectEqual(@as(f32, 33), pos2.x);
    try testing.expectEqual(@as(f32, 44), pos2.y);
}

test "query: single component" {
    var registry = ecs.Registry.init(testing.allocator);
    defer registry.deinit();

    const e1 = registry.create();
    registry.add(e1, Position{ .x = 5, .y = 10 });

    const e2 = registry.create();
    registry.add(e2, Position{ .x = 15, .y = 20 });

    var q = registry.query(.{Position});
    q.each(struct {
        fn run(_: ecs.Entity, pos: *Position) void {
            pos.x *= 2;
        }
    }.run);

    // Verify positions changed
    const pos1 = registry.tryGet(Position, e1).?;
    try testing.expectEqual(@as(f32, 10), pos1.x);

    const pos2 = registry.tryGet(Position, e2).?;
    try testing.expectEqual(@as(f32, 30), pos2.x);
}

test "query: entities without matching components are skipped" {
    var registry = ecs.Registry.init(testing.allocator);
    defer registry.deinit();

    // e1 has both Position and Velocity
    const e1 = registry.create();
    registry.add(e1, Position{ .x = 10, .y = 20 });
    registry.add(e1, Velocity{ .dx = 1, .dy = 2 });

    // e2 only has Position (no Velocity)
    const e2 = registry.create();
    registry.add(e2, Position{ .x = 100, .y = 200 });

    // Query for entities with both Position AND Velocity
    var q = registry.query(.{ Position, Velocity });
    q.each(struct {
        fn run(_: ecs.Entity, pos: *Position, vel: *Velocity) void {
            pos.x += vel.dx;
            pos.y += vel.dy;
        }
    }.run);

    // e1 should be modified (has both components)
    const pos1 = registry.tryGet(Position, e1).?;
    try testing.expectEqual(@as(f32, 11), pos1.x);

    // e2 should NOT be modified (doesn't have Velocity)
    const pos2 = registry.tryGet(Position, e2).?;
    try testing.expectEqual(@as(f32, 100), pos2.x);
}

test "separateComponents: correctly separates data and tag components" {
    const result = ecs.separateComponents(.{ Position, TagPlayer, Velocity });

    comptime {
        std.debug.assert(result.data.len == 2);
        std.debug.assert(result.tags.len == 1);
        std.debug.assert(result.data[0] == Position);
        std.debug.assert(result.data[1] == Velocity);
        std.debug.assert(result.tags[0] == TagPlayer);
    }
}
