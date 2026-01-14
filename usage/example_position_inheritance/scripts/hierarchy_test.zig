// Position Inheritance Validation Script
//
// Tests all position inheritance features:
// 1. Parent-child hierarchy (setParent/removeParent)
// 2. Local vs World position (getLocalPosition, getWorldPosition, setWorldPosition)
// 3. Rotation inheritance (inherit_rotation flag)
// 4. Cascade destroy (destroying parent destroys children)
// 5. Cycle detection (prevents circular hierarchies)

const std = @import("std");
const engine = @import("labelle-engine");

const Game = engine.Game;
const Scene = engine.Scene;
const Position = engine.Position;
const Shape = engine.Shape;
const Color = engine.Color;

var parent_entity: ?engine.Entity = null;
var child_entity: ?engine.Entity = null;
var grandchild_entity: ?engine.Entity = null;
var test_phase: u32 = 0;
var phase_timer: f32 = 0;
var tests_passed: u32 = 0;
var tests_failed: u32 = 0;

pub fn init(game: *Game, scene: *Scene) void {
    _ = scene;

    std.debug.print("\n=== Position Inheritance Validation ===\n\n", .{});

    // Create parent entity (large red circle at 200, 300)
    parent_entity = game.createEntity();
    game.addPosition(parent_entity.?, Position{ .x = 200, .y = 300 });
    game.addShape(parent_entity.?, Shape.circle(40)) catch return;
    if (game.getComponent(Shape, parent_entity.?)) |shape| {
        shape.color = Color{ .r = 255, .g = 50, .b = 50, .a = 255 };
    }

    // Create child entity (medium green circle, offset 100, 0 from parent)
    child_entity = game.createEntity();
    game.addPosition(child_entity.?, Position{ .x = 100, .y = 0 });
    game.addShape(child_entity.?, Shape.circle(25)) catch return;
    if (game.getComponent(Shape, child_entity.?)) |shape| {
        shape.color = Color{ .r = 50, .g = 255, .b = 50, .a = 255 };
    }

    // Create grandchild entity (small blue circle, offset 50, 0 from child)
    grandchild_entity = game.createEntity();
    game.addPosition(grandchild_entity.?, Position{ .x = 50, .y = 0 });
    game.addShape(grandchild_entity.?, Shape.circle(15)) catch return;
    if (game.getComponent(Shape, grandchild_entity.?)) |shape| {
        shape.color = Color{ .r = 50, .g = 50, .b = 255, .a = 255 };
    }

    std.debug.print("Created 3 entities: parent (red), child (green), grandchild (blue)\n", .{});
}

pub fn update(game: *Game, scene: *Scene, dt: f32) void {
    _ = scene;

    phase_timer += dt;

    switch (test_phase) {
        0 => testLocalPosition(game),
        1 => testSetParent(game),
        2 => testWorldPosition(game),
        3 => testSetWorldPosition(game),
        4 => testRotationInheritance(game),
        5 => testCycleDetection(game),
        6 => testCascadeDestroy(game),
        7 => printResults(game),
        else => {},
    }
}

fn testLocalPosition(game: *Game) void {
    if (phase_timer < 0.5) return;

    std.debug.print("\n[Test 1] Local Position API\n", .{});

    const child = child_entity orelse return;

    // Test getLocalPosition
    if (game.getLocalPosition(child)) |pos| {
        if (pos.x == 100 and pos.y == 0) {
            std.debug.print("  PASS: getLocalPosition returns correct local coords (100, 0)\n", .{});
            tests_passed += 1;
        } else {
            std.debug.print("  FAIL: getLocalPosition returned ({}, {}), expected (100, 0)\n", .{ pos.x, pos.y });
            tests_failed += 1;
        }
    }

    // Test setLocalPositionXY
    game.setLocalPositionXY(child, 120, 20);
    if (game.getLocalPosition(child)) |pos| {
        if (pos.x == 120 and pos.y == 20) {
            std.debug.print("  PASS: setLocalPositionXY works correctly\n", .{});
            tests_passed += 1;
        } else {
            std.debug.print("  FAIL: setLocalPositionXY didn't update position\n", .{});
            tests_failed += 1;
        }
    }

    // Reset position
    game.setLocalPositionXY(child, 100, 0);

    test_phase = 1;
    phase_timer = 0;
}

fn testSetParent(game: *Game) void {
    if (phase_timer < 0.5) return;

    std.debug.print("\n[Test 2] Parent-Child Hierarchy\n", .{});

    const parent = parent_entity orelse return;
    const child = child_entity orelse return;
    const grandchild = grandchild_entity orelse return;

    // Set up hierarchy: parent -> child -> grandchild
    game.setParent(child, parent) catch |err| {
        std.debug.print("  FAIL: setParent failed: {}\n", .{err});
        tests_failed += 1;
        test_phase = 2;
        phase_timer = 0;
        return;
    };
    std.debug.print("  PASS: setParent(child, parent) succeeded\n", .{});
    tests_passed += 1;

    game.setParent(grandchild, child) catch |err| {
        std.debug.print("  FAIL: setParent grandchild failed: {}\n", .{err});
        tests_failed += 1;
        test_phase = 2;
        phase_timer = 0;
        return;
    };
    std.debug.print("  PASS: setParent(grandchild, child) succeeded\n", .{});
    tests_passed += 1;

    // Verify hierarchy
    if (game.getParent(child)) |p| {
        if (p == parent) {
            std.debug.print("  PASS: getParent(child) returns parent\n", .{});
            tests_passed += 1;
        } else {
            std.debug.print("  FAIL: getParent(child) returned wrong entity\n", .{});
            tests_failed += 1;
        }
    } else {
        std.debug.print("  FAIL: getParent(child) returned null\n", .{});
        tests_failed += 1;
    }

    if (game.hasChildren(parent)) {
        std.debug.print("  PASS: hasChildren(parent) returns true\n", .{});
        tests_passed += 1;
    } else {
        std.debug.print("  FAIL: hasChildren(parent) returned false\n", .{});
        tests_failed += 1;
    }

    test_phase = 2;
    phase_timer = 0;
}

fn testWorldPosition(game: *Game) void {
    if (phase_timer < 0.5) return;

    std.debug.print("\n[Test 3] World Position Calculation\n", .{});

    const child = child_entity orelse return;
    const grandchild = grandchild_entity orelse return;

    // Parent at (200, 300), child offset (100, 0) -> child world = (300, 300)
    if (game.getWorldPosition(child)) |world_pos| {
        if (world_pos.x == 300 and world_pos.y == 300) {
            std.debug.print("  PASS: child world position = (300, 300)\n", .{});
            tests_passed += 1;
        } else {
            std.debug.print("  FAIL: child world position = ({}, {}), expected (300, 300)\n", .{ world_pos.x, world_pos.y });
            tests_failed += 1;
        }
    }

    // Grandchild: parent(200,300) + child(100,0) + grandchild(50,0) = (350, 300)
    if (game.getWorldPosition(grandchild)) |world_pos| {
        if (world_pos.x == 350 and world_pos.y == 300) {
            std.debug.print("  PASS: grandchild world position = (350, 300)\n", .{});
            tests_passed += 1;
        } else {
            std.debug.print("  FAIL: grandchild world position = ({}, {}), expected (350, 300)\n", .{ world_pos.x, world_pos.y });
            tests_failed += 1;
        }
    }

    test_phase = 3;
    phase_timer = 0;
}

fn testSetWorldPosition(game: *Game) void {
    if (phase_timer < 0.5) return;

    std.debug.print("\n[Test 4] Set World Position\n", .{});

    const child = child_entity orelse return;

    // Set child's world position to (400, 350)
    // Parent is at (200, 300), so local should become (200, 50)
    game.setWorldPosition(child, 400, 350);

    if (game.getLocalPosition(child)) |local_pos| {
        if (local_pos.x == 200 and local_pos.y == 50) {
            std.debug.print("  PASS: setWorldPosition correctly computed local offset (200, 50)\n", .{});
            tests_passed += 1;
        } else {
            std.debug.print("  FAIL: local position = ({}, {}), expected (200, 50)\n", .{ local_pos.x, local_pos.y });
            tests_failed += 1;
        }
    }

    // Verify world position is correct
    if (game.getWorldPosition(child)) |world_pos| {
        if (world_pos.x == 400 and world_pos.y == 350) {
            std.debug.print("  PASS: getWorldPosition confirms (400, 350)\n", .{});
            tests_passed += 1;
        } else {
            std.debug.print("  FAIL: world position = ({}, {}), expected (400, 350)\n", .{ world_pos.x, world_pos.y });
            tests_failed += 1;
        }
    }

    // Reset child position
    game.setLocalPositionXY(child, 100, 0);

    test_phase = 4;
    phase_timer = 0;
}

fn testRotationInheritance(game: *Game) void {
    if (phase_timer < 0.5) return;

    std.debug.print("\n[Test 5] Rotation Inheritance\n", .{});

    const parent = parent_entity orelse return;
    const child = child_entity orelse return;

    // Set parent rotation to 90 degrees (PI/2)
    if (game.getLocalPosition(parent)) |pos| {
        pos.rotation = std.math.pi / 2.0;
    }

    // Remove existing parent first, then re-add with rotation inheritance
    game.removeParent(child);

    // Enable rotation inheritance on child
    game.setParentWithOptions(child, parent, true, false) catch |err| {
        std.debug.print("  FAIL: setParentWithOptions failed: {}\n", .{err});
        tests_failed += 1;
        test_phase = 5;
        phase_timer = 0;
        return;
    };
    std.debug.print("  PASS: setParentWithOptions(inherit_rotation=true) succeeded\n", .{});
    tests_passed += 1;

    // With rotation inheritance, child at local (100, 0) should be at world (~200, 400)
    // because 90 degree rotation transforms (100, 0) to (0, 100)
    if (game.getWorldTransform(child)) |transform| {
        // Expected: parent(200,300) + rotated(100,0) = (200, 400)
        const expected_x: f32 = 200;
        const expected_y: f32 = 400;
        const tolerance: f32 = 1.0;

        if (@abs(transform.x - expected_x) < tolerance and @abs(transform.y - expected_y) < tolerance) {
            std.debug.print("  PASS: rotation inheritance transforms child position correctly\n", .{});
            tests_passed += 1;
        } else {
            std.debug.print("  FAIL: world position = ({d:.1}, {d:.1}), expected ({d:.1}, {d:.1})\n", .{ transform.x, transform.y, expected_x, expected_y });
            tests_failed += 1;
        }

        // Check rotation is inherited
        const expected_rotation = std.math.pi / 2.0;
        if (@abs(transform.rotation - expected_rotation) < 0.01) {
            std.debug.print("  PASS: rotation is inherited (PI/2)\n", .{});
            tests_passed += 1;
        } else {
            std.debug.print("  FAIL: rotation = {d:.2}, expected {d:.2}\n", .{ transform.rotation, expected_rotation });
            tests_failed += 1;
        }
    }

    // Reset parent rotation
    if (game.getLocalPosition(parent)) |pos| {
        pos.rotation = 0;
    }
    // Reset to no rotation inheritance
    game.setParent(child, parent) catch {};

    test_phase = 5;
    phase_timer = 0;
}

fn testCycleDetection(game: *Game) void {
    if (phase_timer < 0.5) return;

    std.debug.print("\n[Test 6] Cycle Detection\n", .{});

    const parent = parent_entity orelse return;
    const child = child_entity orelse return;

    // Try to create a cycle: parent -> child, then child -> parent (should fail)
    if (game.setParent(parent, child)) {
        std.debug.print("  FAIL: setParent allowed circular hierarchy!\n", .{});
        tests_failed += 1;
        // Undo the bad parenting
        game.removeParent(parent);
    } else |err| {
        if (err == Game.HierarchyError.CircularHierarchy) {
            std.debug.print("  PASS: CircularHierarchy error correctly detected\n", .{});
            tests_passed += 1;
        } else {
            std.debug.print("  PASS: Cycle prevented with error: {}\n", .{err});
            tests_passed += 1;
        }
    }

    // Test self-parenting
    if (game.setParent(parent, parent)) {
        std.debug.print("  FAIL: setParent allowed self-parenting!\n", .{});
        tests_failed += 1;
    } else |err| {
        if (err == Game.HierarchyError.SelfParenting) {
            std.debug.print("  PASS: SelfParenting error correctly detected\n", .{});
            tests_passed += 1;
        } else {
            std.debug.print("  PASS: Self-parenting prevented with error: {}\n", .{err});
            tests_passed += 1;
        }
    }

    test_phase = 6;
    phase_timer = 0;
}

fn testCascadeDestroy(game: *Game) void {
    if (phase_timer < 0.5) return;

    std.debug.print("\n[Test 7] Cascade Destroy\n", .{});

    // Create a new hierarchy for destruction test
    const test_parent = game.createEntity();
    game.addPosition(test_parent, Position{ .x = 500, .y = 300 });

    const test_child = game.createEntity();
    game.addPosition(test_child, Position{ .x = 50, .y = 0 });
    game.setParent(test_child, test_parent) catch {};

    const test_grandchild = game.createEntity();
    game.addPosition(test_grandchild, Position{ .x = 25, .y = 0 });
    game.setParent(test_grandchild, test_child) catch {};

    std.debug.print("  Created test hierarchy for destruction\n", .{});

    // Destroy parent - should cascade to children
    game.destroyEntity(test_parent);

    // Verify children are also destroyed (getLocalPosition should return null)
    if (game.getLocalPosition(test_child) == null and game.getLocalPosition(test_grandchild) == null) {
        std.debug.print("  PASS: Cascade destroy removed all children\n", .{});
        tests_passed += 1;
    } else {
        std.debug.print("  FAIL: Children still exist after parent destruction\n", .{});
        tests_failed += 1;
    }

    test_phase = 7;
    phase_timer = 0;
}

fn printResults(game: *Game) void {
    if (phase_timer < 0.5) return;

    std.debug.print("\n=== Test Results ===\n", .{});
    std.debug.print("Passed: {}\n", .{tests_passed});
    std.debug.print("Failed: {}\n", .{tests_failed});
    std.debug.print("Total:  {}\n", .{tests_passed + tests_failed});

    if (tests_failed == 0) {
        std.debug.print("\nAll tests PASSED!\n", .{});
    } else {
        std.debug.print("\nSome tests FAILED.\n", .{});
    }

    // Exit after showing results
    test_phase = 8;
    game.quit();
}

pub fn deinit(game: *Game, scene: *Scene) void {
    _ = game;
    _ = scene;
    std.debug.print("\nPosition inheritance validation complete.\n", .{});
}
